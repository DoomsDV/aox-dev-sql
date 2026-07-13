const functions = require('@google-cloud/functions-framework');
const admin = require('firebase-admin');

// Inicializa Firebase Admin (Toma los permisos de Google Cloud automáticamente)
if (!admin.apps.length) {
    admin.initializeApp();
}

functions.http('enviarPush', async (req, res) => {
  // 1. Validar nuestra contraseña secreta
  const tokenSecreto = "n@SwK$@f^3fGn3Ha#e9XwScW#1Avy%rahW^QUN7$hbs4Zjdb7TAtmP*6ge3RGE"; 
  if (req.headers.authorization !== `Bearer ${tokenSecreto}`) {
    return res.status(401).send({ error: "No autorizado" });
  }

  try {
    // 2. Solo aceptamos peticiones POST
    if (req.method !== 'POST') {
      return res.status(405).send({ error: "Método no permitido" });
    }

    // 3. Extraer los datos que mandó Oracle APEX
    const { fcm_token, title, body, url } = req.body;
    const fallbackUrl = process.env.APP_PUBLIC_BASE_URL
      ? `${String(process.env.APP_PUBLIC_BASE_URL).replace(/\/+$/, '')}/panel/calendar`
      : 'https://hasel.app/panel/calendar';

    if (!fcm_token) {
      return res.status(400).send({ error: "Falta el fcm_token" });
    }

    const targetUrl = String(url || fallbackUrl).trim() || fallbackUrl;
    const orgMemberMatch = targetUrl.match(/[?&]org_member_id=(\d+)/i);
    const orgMemberId = orgMemberMatch ? String(orgMemberMatch[1]) : '';

    // 4. Armar el mensaje para el celular
    const mensaje = {
      token: fcm_token,
      notification: {
        title: title || "Nueva Notificación",
        body: body || ""
      },
      data: {
        url: targetUrl,
        org_member_id: orgMemberId,
      },
      // CONFIGURACIÓN PARA PWA (Navegadores)
      webpush: {
        headers: {
          Urgency: 'high' // Obliga al navegador a procesar el push de inmediato
        },
        fcm_options: {
          link: targetUrl
        }
      },
      // CONFIGURACIÓN PARA ANDROID (Opcional, pero recomendado)
      android: {
        priority: 'high' // Despierta el dispositivo si está en modo reposo (Doze)
      },
      // CONFIGURACIÓN PARA iOS/APNs (Opcional, pero recomendado)
      apns: {
        headers: {
          'apns-priority': '10' // 10 es prioridad máxima en Apple
        }
      }
    };

    // 5. Disparar el Push a través de Firebase
    const response = await admin.messaging().send(mensaje);
    res.status(200).send({ success: true, messageId: response });

  } catch (error) {
    console.error("Error enviando push:", error);
    res.status(500).send({ success: false, error: error.message });
  }
});