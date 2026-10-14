# Cita Clara

Plataforma para que médicos, dentistas y psicólogos publiquen sus consultorios y horarios, y para que los pacientes encuentren y agenden citas (similar a Doctoralia).

## Estructura
- `prototipo/index.html`: prototipo visual con datos de ejemplo (inicio, resultados, perfil, registro de profesional). Se abre directo en el navegador.
- `supabase/migrations/0001_init.sql`: base de datos (PostgreSQL en Supabase): tablas, reglas de seguridad por fila y catálogo de especialidades.

## Base de datos
Tablas principales: `profiles`, `professionals`, `specialties`, `professional_specialties`, `offices`, `office_schedules`, `appointments`.

- Un médico puede tener varias especialidades.
- Cada profesional puede tener varios consultorios, cada uno con su dirección y horario semanal.
- Las citas no pueden traslaparse para un mismo profesional.
- El público solo ve profesionales con estado `verified`.

Para aplicarla: Supabase → SQL Editor → pegar el contenido de `0001_init.sql` → Run. Se puede ejecutar más de una vez sin problema.

## Siguiente
- Conectar el prototipo a Supabase (registro, búsqueda y agenda reales).
