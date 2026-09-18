import { createClient } from '@supabase/supabase-js';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({
      error: 'Méthode non autorisée.'
    });
  }

  const url = process.env.SUPABASE_URL;
  const service = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !service) {
    return res.status(500).json({
      error: 'Variables Supabase manquantes.'
    });
  }

  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ')
    ? auth.slice(7)
    : null;

  if (!token) {
    return res.status(401).json({
      error: 'Session manquante.'
    });
  }

  const admin = createClient(url, service, {
    auth: {
      autoRefreshToken: false,
      persistSession: false
    }
  });

  const {
    data: userData,
    error: userError
  } = await admin.auth.getUser(token);

  if (userError || !userData?.user) {
    return res.status(401).json({
      error: 'Session invalide.'
    });
  }

  const callerId = userData.user.id;

  const {
    data: profile,
    error: profileError
  } = await admin
    .from('profiles')
    .select('role')
    .eq('id', callerId)
    .single();

  if (profileError || profile?.role !== 'admin') {
    return res.status(403).json({
      error: 'Réservé au patron / administrateur.'
    });
  }

  const {
    email,
    display_name,
    role
  } = req.body || {};

  if (
    !email ||
    !display_name ||
    !['admin', 'employee', 'viewer'].includes(role)
  ) {
    return res.status(400).json({
      error: 'Nom, email ou rôle invalide.'
    });
  }

  const {
    data,
    error
  } = await admin.auth.admin.inviteUserByEmail(
    email,
    {
      redirectTo: process.env.SITE_URL || undefined,
      data: {
        display_name
      }
    }
  );

  if (error) {
    return res.status(400).json({
      error: error.message
    });
  }

  if (data?.user?.id) {
    const {
      error: profileUpdateError
    } = await admin
      .from('profiles')
      .upsert({
        id: data.user.id,
        email,
        display_name,
        role
      });

    if (profileUpdateError) {
      return res.status(500).json({
        error:
          "L'invitation a été envoyée, mais le rôle n'a pas pu être enregistré : " +
          profileUpdateError.message
      });
    }
  }

  return res.status(200).json({
    ok: true
  });
}
