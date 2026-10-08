# AulaEval 3.0 — despliegue y migración desde V2

## Qué incluye
Se mantienen las siete rúbricas (100 puntos), estudiantes, asignaturas, períodos, edición de notas, observaciones, autoguardado y reportes PDF/Excel. Ahora se agregan inicio de sesión sin pantalla de conexión, recuperación de contraseña, espacios personales y colegios compartidos con invitaciones de un solo uso.

## IMPORTANTE: migración de producción
1. **Haz un respaldo verificable de Supabase** y exporta las tablas `students`, `subjects`, `periods`, `enrollments`, `evaluations`. Conserva la versión V2 publicada hasta verificar V3.
2. En Supabase SQL Editor ejecuta `MIGRACION_V3.sql` **una sola vez**, únicamente si ya aplicaste `MIGRACION_V2.sql`. No ejecutes las migraciones antiguas nuevamente.
3. La migración crea un espacio personal por cada docente existente y asigna allí sus registros anteriores. **No elimina intencionalmente registros ni calificaciones.**
4. En Netlify usa el repositorio/carpeta V3 como origen de build. Configura:
   - `SUPABASE_URL` = `https://TU-PROYECTO.supabase.co`
   - `SUPABASE_PUBLISHABLE_KEY` = clave pública `sb_publishable_...` (o anon JWT público)
   - **NUNCA** introduzcas `service_role` ni una secret key.
5. Configura Netlify: comando de compilación `npm run build`, directorio de publicación `dist` (también definidos en `netlify.toml`). Necesita Node.js 20+.
6. En Supabase → Authentication → URL Configuration: configura `Site URL` con tu URL HTTPS de Netlify y agrega la URL permitida a `Redirect URLs` (por ejemplo `https://tu-sitio.netlify.app/**`).
7. En Supabase → Authentication → Providers → Email, habilita el proveedor de correo. Para cuentas reales usa un servicio SMTP configurado y verifica el flujo de recuperación de contraseña.
8. Abre la URL publicada. Los docentes solo verán correo y contraseña; no deberán configurar Supabase. Si ya tienen cuenta pueden entrar normalmente.

## Cómo utilizar los espacios
- Cada usuario dispone de un **espacio personal** privado.
- Para compartir cursos, entra en **Gestionar espacios** → **Crear colegio compartido**.
- Dentro del colegio, un administrador puede generar un **código de invitación** de 64 caracteres, válido 7 días y de un solo uso. Envíalo únicamente por un canal privado.
- El docente invitado crea/inicia su cuenta y utiliza **Unirme con un código de invitación**.
- Selecciona el espacio activo en la barra lateral. Cada espacio tiene sus propios estudiantes, materias, períodos y evaluaciones.
- Los datos antiguos de V2 permanecen en el espacio personal. No se copian automáticamente al colegio compartido.
- Los miembros del colegio **pueden ver y editar todas las calificaciones del colegio**, incluso las creadas por otros docentes. Los administradores pueden retirar docentes; esta versión no implementa permisos por asignatura.

## Restricciones y seguridad
- RLS se aplica en Supabase a todas las tablas académicas y de espacios. La migración incluye triggers para impedir relaciones entre distintos espacios y modificaciones del propietario original.
- La clave publishable es pública por diseño. El acceso se controla con Supabase Auth + RLS, no ocultando esa clave.
- Las invitaciones no se muestran otra vez después de crearlas. Si se extravían, genera otra.
- El navegador guarda la sesión autenticada; la configuración pública se genera durante la compilación.
- Si un docente elimina un estudiante, sus calificaciones asociadas se borran por cascada. Haz respaldos y usa un entorno de pruebas antes de compartir el sitio.
- No hay historial de auditoría, deshacer eliminaciones, control de edición concurrente ni permisos granulares por asignatura.
- El modo sin conexión no está disponible. Comprueba el indicador de guardado.
- Los PDF/Excel dependen de bibliotecas externas cargadas desde CDN.
- El código está preparado pero **no ha sido validado contra tu Supabase real**. Es necesario probar RLS y migración en una copia antes de producción.

## Archivos
- `MIGRACION_V3.sql`: migración sobre V2.
- `index.html`, `styles.css`, `app.js`: aplicación.
- `scripts/build.mjs`: genera `dist/config.js` con configuración pública desde Netlify.
- `package.json`, `netlify.toml`: compilación y despliegue.

## Prueba mínima de aceptación
1. Crear dos cuentas y confirmar que cada una tiene su espacio personal separado.
2. Entrar desde otro navegador sin pantalla de conexión.
3. Crear colegio, generar invitación, unir segundo docente.
4. Registrar un estudiante y evaluación en el colegio y comprobar que ambos miembros pueden verla y editarla.
5. Retirar segundo docente y comprobar que ya no puede leer ni escribir datos del colegio.
6. Confirmar que ambos espacios personales siguen privados.
7. Modificar una nota y verificar persistencia y reportes PDF/Excel.
8. Probar recuperación de contraseña desde un navegador nuevo.
