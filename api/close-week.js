import { createClient } from '@supabase/supabase-js';

function parisParts() {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Paris',
    weekday: 'long',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23'
  }).formatToParts(new Date());

  return Object.fromEntries(parts.map(p => [p.type, p.value]));
}

function localISODate(parts) {
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export default async function handler(req, res) {
  if (!['GET', 'POST'].includes(req.method)) {
    return res.status(405).json({
      error: 'Méthode non autorisée.'
    });
  }

  const url = process.env.SUPABASE_URL;
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const cronSecret = process.env.CRON_SECRET;

  if (!url || !service) {
    return res.status(500).json({
      error: 'Variables Supabase manquantes.'
    });
  }

  const admin = createClient(url, service, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });

  const auth = req.headers.authorization || '';

  let closedBy = null;
  let manual = false;

  if (req.method === 'GET') {
    if (!cronSecret || auth !== `Bearer ${cronSecret}`) {
      return res.status(401).json({
        error: 'Cron non autorisé.'
      });
    }
  } else {
    const token = auth.startsWith('Bearer ')
      ? auth.slice(7)
      : null;

    if (!token) {
      return res.status(401).json({
        error: 'Session manquante.'
      });
    }

    const {
      data: userData,
      error: userError
    } = await admin.auth.getUser(token);

    if (userError || !userData?.user) {
      return res.status(401).json({
        error: 'Session invalide.'
      });
    }

    closedBy = userData.user.id;

    const {
      data: profile,
      error: profileError
    } = await admin
      .from('profiles')
      .select('role')
      .eq('id', closedBy)
      .single();

    if (profileError || profile?.role !== 'admin') {
      return res.status(403).json({
        error: 'Réservé au patron / administrateur.'
      });
    }

    manual = true;
  }

  const {
    data: period,
    error: periodError
  } = await admin
    .from('accounting_periods')
    .select('*')
    .eq('status', 'open')
    .single();

  if (periodError) {
    return res.status(500).json({
      error: periodError.message
    });
  }

  const parts = parisParts();
  const localDate = localISODate(parts);

  if (!manual) {
    if (!(parts.weekday === 'Friday' && parts.hour === '00')) {
      return res.status(200).json({
        ok: true,
        skipped: true,
        reason: "Pas l'heure locale de clôture."
      });
    }

    if (localDate <= period.period_end) {
      return res.status(200).json({
        ok: true,
        skipped: true,
        reason: "Période pas encore arrivée à échéance."
      });
    }
  } else {
    if (localDate < period.period_end) {
      return res.status(400).json({
        error: `La clôture manuelle sera disponible à partir du ${period.period_end}.`
      });
    }
  }

  const {
    data,
    error
  } = await admin.rpc('close_current_period', {
    p_closed_by: closedBy
  });

  if (error) {
    return res.status(500).json({
      error: error.message
    });
  }

  return res.status(200).json({
    ok: true,
    closed_period_id: data
  });
}
