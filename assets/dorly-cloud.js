/* =========================================================
   Dorly cloud layer — Supabase (database, auth, storage)
   Both pages keep their in-memory `DB` object; this file loads it
   from Supabase and writes back only what changed on save().
   Security is enforced in the database (RLS + guard triggers),
   not here: the publishable key below is safe to ship to browsers.
   ========================================================= */
(function () {
  const SUPABASE_URL = 'https://sayqxowybxpqmqfshmqk.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_jDHReWaAW3IG17hg1FApLQ_gt72LR2w';
  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'dorly-auth' }
  });

  // collection name in DB  ->  table, ordering ("prepend" = newest first like unshift)
  const T = {
    sellers:    { table: 'dorly_sellers',    order: 'append'  },
    listings:   { table: 'dorly_listings',   order: 'prepend' },
    inquiries:  { table: 'dorly_inquiries',  order: 'prepend' },
    complaints: { table: 'dorly_complaints', order: 'append'  },
    verifs:     { table: 'dorly_verifs',     order: 'append'  },
    audit:      { table: 'dorly_audit',      order: 'prepend' }
  };
  const PRIVATE_KEYS = ['address', 'crNo', 'taxNo', 'owner', 'whatsapp']; // seller profile fields never shown publicly (whatsapp: members only)
  const LISTING_PRIVATE = ['imei', 'whatsapp'];   // listing form fields kept in dorly_listing_private (owner + admin)
  const LOGIN_DOMAIN = '@phone.dorly.app';

  let snap = {};                 // coll -> Map(id -> serialized json)
  let privSnap = new Map();      // seller id -> serialized private json
  let lPrivSnap = new Map();     // listing id -> serialized private json
  let userSnap = new Map();      // profile id -> disabled flag
  const pathOf = new Map();      // displayed image src (signed URL / data URL) -> 'sbp:<path>'
  let session = null, profile = null;
  let chain = Promise.resolve();

  const clone = o => JSON.parse(JSON.stringify(o));
  const loginFor = phone => 'p' + phone + LOGIN_DOMAIN;

  async function selectAll(table) {
    const out = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await sb.from(table).select('*').order('created_at', { ascending: true }).range(from, from + 999);
      if (error) throw error;
      out.push(...data);
      if (data.length < 1000) return out;
    }
  }
  function ordered(rows, mode) {
    if (mode === 'append') return rows;
    // sample rows keep their original order at the end; real rows newest first
    const real = rows.filter(r => !r.sample).reverse(), sample = rows.filter(r => r.sample);
    return real.concat(sample);
  }

  /* ---------- serialization (what is stored in the `data` column) ---------- */
  function serialize(coll, obj) {
    const o = clone(obj);
    if (coll === 'sellers' && o.profile) {
      if ('whatsapp' in o.profile) o.profile.wa = !!o.profile.whatsapp;   // public flag only
      PRIVATE_KEYS.forEach(k => delete o.profile[k]);
    }
    if (coll === 'listings' && o.shots) for (const k in o.shots) { const p = pathOf.get(o.shots[k]); if (p) o.shots[k] = p; }
    if (coll === 'listings' && o.form) {
      if ('whatsapp' in o.form) o.wa = !!o.form.whatsapp;          // public flag only
      LISTING_PRIVATE.forEach(k => delete o.form[k]);
    }
    return o;
  }
  const lPrivOf = l => { const f = l.form || {}, o = {}; LISTING_PRIVATE.forEach(k => { if (f[k] != null && f[k] !== '') o[k] = f[k]; }); return o; };
  const privOf = s => { const p = s.profile || {}, o = {}; PRIVATE_KEYS.forEach(k => { if (p[k] != null && p[k] !== '') o[k] = p[k]; }); return o; };

  /* ---------- photos -> Supabase Storage ---------- */
  async function upload(bucket, dataUrl, name) {
    const blob = await (await fetch(dataUrl)).blob();
    const ext = blob.type === 'image/png' ? 'png' : blob.type === 'image/webp' ? 'webp' : 'jpg';
    const path = `${session.user.id}/${name}-${Math.random().toString(36).slice(2, 8)}.${ext}`;
    const { error } = await sb.storage.from(bucket).upload(path, blob, { contentType: blob.type || 'image/jpeg', upsert: false });
    if (error) throw error;
    return path;
  }
  async function uploadMedia(live, out) {
    if (!session) return;
    if (out.pubPhotos) for (const k in out.pubPhotos) {
      const v = out.pubPhotos[k];
      if (typeof v === 'string' && v.startsWith('data:')) {
        const path = await upload('dorly-public', v, `listings/${live.id}/${k}`);
        const url = sb.storage.from('dorly-public').getPublicUrl(path).data.publicUrl;
        out.pubPhotos[k] = url; live.pubPhotos[k] = url;
      }
    }
    if (Array.isArray(out.photos)) for (let i = 0; i < out.photos.length; i++) {
      const v = out.photos[i];
      if (typeof v === 'string' && v.startsWith('data:')) {
        const path = await upload('dorly-public', v, `listings/${live.id}/p${i}`);
        const url = sb.storage.from('dorly-public').getPublicUrl(path).data.publicUrl;
        out.photos[i] = url; live.photos[i] = url;
      }
    }
    if (out.shots) for (const k in out.shots) {   // settings screenshots stay private (owner + admin)
      const v = out.shots[k];
      if (typeof v === 'string' && v.startsWith('data:')) {
        const ref = 'sbp:' + await upload('dorly-private', v, `listings/${live.id}/${k}`);
        out.shots[k] = ref; pathOf.set(v, ref);
      }
    }
  }
  async function signShots(listings) {
    const refs = [];
    listings.forEach(l => { if (l.shots) for (const k in l.shots) if (String(l.shots[k]).startsWith('sbp:')) refs.push([l, k]); });
    if (!refs.length || !session) return;
    const { data } = await sb.storage.from('dorly-private').createSignedUrls(refs.map(([l, k]) => l.shots[k].slice(4)), 3600);
    (data || []).forEach((d, i) => {
      const [l, k] = refs[i];
      if (d && d.signedUrl) { pathOf.set(d.signedUrl, l.shots[k]); l.shots[k] = d.signedUrl; }
    });
  }

  // Defensive shape fixes so one malformed row cannot crash rendering for everybody.
  // Applied before the snapshot is taken, so it never causes a write by itself.
  function normalize(c, o) {
    if (c === 'sellers') {
      if (!Array.isArray(o.badges)) o.badges = [];
      o.badges = o.badges.filter(b => typeof b === 'string');
      if (o.profile != null && typeof o.profile !== 'object') o.profile = {};
    }
    if (c === 'listings' && 'acc' in o && !Array.isArray(o.acc)) o.acc = [];
    if (c === 'verifs' && !Array.isArray(o.docs)) o.docs = [];
    return o;
  }

  /* ---------- load everything this visitor is allowed to see ---------- */
  async function load() {
    session = (await sb.auth.getSession()).data.session;
    profile = null;
    Cloud.disabledNotice = false;
    if (session) {
      const { data } = await sb.from('dorly_profiles').select('*').eq('id', session.user.id).maybeSingle();
      profile = data || null;
      if (!profile || profile.disabled) {
        Cloud.disabledNotice = !!(profile && profile.disabled);
        await sb.auth.signOut(); session = null; profile = null;
      }
    }
    const DB = { users: [] }, colls = Object.keys(T);
    const res = await Promise.all(colls.map(c => selectAll(T[c].table)));
    snap = {};
    colls.forEach((c, i) => {
      const rows = ordered(res[i], T[c].order);
      DB[c] = rows.map(r => normalize(c, Object.assign({}, r.data, { id: r.id })));
      snap[c] = new Map(DB[c].map(o => [o.id, JSON.stringify(serialize(c, o))]));
    });
    privSnap = new Map(); lPrivSnap = new Map();
    if (session) {
      const { data: priv } = await sb.from('dorly_seller_private').select('*');
      (priv || []).forEach(p => {
        const s = DB.sellers.find(x => x.id === p.seller_id);
        if (s) { s.profile = Object.assign({}, s.profile || {}, p.data); privSnap.set(s.id, JSON.stringify(privOf(s))); }
      });
      snap.sellers = new Map(DB.sellers.map(o => [o.id, JSON.stringify(serialize('sellers', o))]));
      const { data: users } = await sb.from('dorly_profiles').select('*').order('created_at');
      DB.users = (users || []).map(u => ({ id: u.id, role: u.role, name: u.name, phone: u.phone, email: u.email, sellerId: u.seller_id || undefined, created: u.created, disabled: u.disabled }));
      await signShots(DB.listings);
      lPrivSnap = new Map();
      const { data: lpriv } = await sb.from('dorly_listing_private').select('*');
      (lpriv || []).forEach(p => {
        const l = DB.listings.find(x => x.id === p.listing_id);
        if (l) { l.form = Object.assign({}, l.form || {}, p.data); lPrivSnap.set(l.id, JSON.stringify(lPrivOf(l))); }
      });
      snap.listings = new Map(DB.listings.map(o => [o.id, JSON.stringify(serialize('listings', o))]));
    }
    userSnap = new Map(DB.users.map(u => [u.id, !!u.disabled]));
    return DB;
  }

  // copy server-side values back onto the in-memory object (media and private profile fields stay as they are)
  const KEEP_LOCAL = ['pubPhotos', 'shots', 'photos', 'profile', 'form'];   // these hold private/media fields the server copy lacks
  function adoptServer(live, data) {
    if (!data) return;
    for (const k in data) if (!KEEP_LOCAL.includes(k) && JSON.stringify(live[k]) !== JSON.stringify(data[k])) live[k] = data[k];
  }

  /* ---------- write back only what changed ---------- */
  async function doSync(DB) {
    const errs = [];
    for (const c of Object.keys(T)) {
      const prev = snap[c] || (snap[c] = new Map()), seen = new Set();
      for (const live of DB[c] || []) {
        seen.add(live.id);
        let out = serialize(c, live), js = JSON.stringify(out);
        if (prev.get(live.id) !== js) {
          try {
            if (c === 'listings') { await uploadMedia(live, out); js = JSON.stringify(out); }
            const row = { id: live.id, data: out };
            if (out.seller) row.seller_id = out.seller;
            if (c === 'listings' || c === 'verifs') row.status = out.status;
            let r;
            if (prev.has(live.id)) {
              r = await sb.from(T[c].table).update(row).eq('id', live.id).select('id, data');
              if (!r.error && !(r.data || []).length) r.error = { message: 'not allowed' };
              // the database may override protected fields (payment, level, badges...): show what it stored
              if (!r.error) adoptServer(live, r.data[0].data);
            } else r = await sb.from(T[c].table).insert(row);
            if (r.error) throw r.error;
            prev.set(live.id, JSON.stringify(serialize(c, live)));
          } catch (e) { errs.push(c + ':' + (e.message || e)); }
        }
        if (c === 'listings' && session && prev.has(live.id)) {   // private listing fields (after the listing exists)
          const p = JSON.stringify(lPrivOf(live));
          if ((lPrivSnap.get(live.id) || '{}') !== p && (lPrivSnap.has(live.id) || p !== '{}')) {
            const r = lPrivSnap.has(live.id)
              ? await sb.from('dorly_listing_private').update({ data: JSON.parse(p) }).eq('listing_id', live.id).select('listing_id')
              : await sb.from('dorly_listing_private').insert({ listing_id: live.id, data: JSON.parse(p) });
            if (r.error || (lPrivSnap.has(live.id) && !(r.data || []).length)) errs.push('listing_private'); else lPrivSnap.set(live.id, p);
          }
        }
        if (c === 'sellers' && session) {          // private seller fields
          const p = JSON.stringify(privOf(live));
          if ((privSnap.get(live.id) || '{}') !== p && (privSnap.has(live.id) || p !== '{}')) {
            const r = privSnap.has(live.id)
              ? await sb.from('dorly_seller_private').update({ data: JSON.parse(p) }).eq('seller_id', live.id).select('seller_id')
              : await sb.from('dorly_seller_private').insert({ seller_id: live.id, data: JSON.parse(p) });
            if (r.error || (privSnap.has(live.id) && !(r.data || []).length)) errs.push('seller_private'); else privSnap.set(live.id, p);
          }
        }
      }
      if (c === 'audit') continue;                  // the audit log is append-only
      for (const id of [...prev.keys()]) if (!seen.has(id)) {
        const r = await sb.from(T[c].table).delete().eq('id', id).select('id');
        if (r.error || !(r.data || []).length) errs.push(c + ':delete'); else prev.delete(id);
      }
    }
    for (const u of DB.users || []) {               // admins can (de)activate accounts
      if (userSnap.has(u.id) && userSnap.get(u.id) !== !!u.disabled) {
        const r = await sb.from('dorly_profiles').update({ disabled: !!u.disabled }).eq('id', u.id).select('id');
        if (r.error || !(r.data || []).length) errs.push('users'); else userSnap.set(u.id, !!u.disabled);
      }
    }
    if (errs.length) {
      console.warn('Dorly sync errors', errs);
      if (typeof toast === 'function') toast('ماقدرناش نحفظ التغيير ده — اتأكد إنك داخل بحسابك وجرّب تاني');
      await reload();
    }
  }
  function sync(DB) { chain = chain.then(() => doSync(DB)).catch(e => console.error(e)); return chain; }
  async function reload() { const db = await load(); if (typeof Cloud.onReload === 'function') Cloud.onReload(db); return db; }

  /* ---------- auth ---------- */
  function user() {
    if (!profile) return null;
    return { uid: profile.id, name: profile.name, role: profile.role, phone: profile.phone, email: profile.email, sellerId: profile.seller_id || undefined };
  }
  async function signIn(ident, password, phoneNorm) {
    let email = phoneNorm ? loginFor(phoneNorm) : null;
    if (!email) {
      const { data } = await sb.rpc('dorly_login_email', { ident: String(ident).trim() });
      email = data;
    }
    if (!email) return { error: 'bad' };
    const { error } = await sb.auth.signInWithPassword({ email, password });
    if (error) return { error: 'bad' };
    const db = await load();
    if (Cloud.disabledNotice) return { error: 'disabled' };
    if (!profile) return { error: 'bad' };
    return { db };
  }
  async function signUp(payload) {
    const { data, error } = await sb.functions.invoke('dorly-signup', { body: payload });
    if (error) {
      let code = 'create_failed';
      try { code = (await error.context.json()).error || code; } catch (e) { }
      return { error: code };
    }
    const r = await signIn(null, payload.password, payload.phone);
    return r.error ? { error: 'login_failed' } : Object.assign({ sellerId: data.sellerId }, r);
  }
  async function taken(phone, email) {
    const { data } = await sb.rpc('dorly_taken', { p_phone: phone, p_email: email || '' });
    return data || null;
  }
  // WhatsApp number to contact about a listing (listing's own, else the seller's), members only
  async function listingWhatsapp(lid) {
    const { data } = await sb.rpc('dorly_listing_whatsapp', { lid });
    return data || null;
  }
  // a seller's WhatsApp number, only for signed-in members
  async function sellerWhatsapp(sid) {
    const { data } = await sb.rpc('dorly_seller_whatsapp', { sid });
    return data || null;
  }
  async function signOut() { await sb.auth.signOut(); session = null; profile = null; }
  // SMS codes (Twilio Verify, through the dorly-otp Edge Function)
  async function otp(body) {
    const { data, error } = await sb.functions.invoke('dorly-otp', { body });
    if (error) {
      let code = 'failed';
      try { code = (await error.context.json()).error || code; } catch (e) { }
      return { error: code };
    }
    return data || {};
  }

  const Cloud = { sb, load, sync, reload, user, signIn, signUp, signOut, taken, otp, sellerWhatsapp, listingWhatsapp, onReload: null, disabledNotice: false };
  window.Cloud = Cloud;
})();
