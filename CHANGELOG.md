# Changelog

Tutte le modifiche rilevanti del modulo sono riportate qui.
Formato basato su [Keep a Changelog](https://keepachangelog.com/it-IT/1.1.0/),
versioni secondo [Semantic Versioning](https://semver.org/lang/it/).

## [Non rilasciato]

## [1.0.0] - 2026-11-24

Prima versione pubblica.

### Funzionalità
- **Ciclo di carica con isteresi** (default 20–80%) tramite il nodo kernel `input_suspend`,
  con ripartenza immediata quando colleghi il cavo sotto la soglia (`CHARGE_ON_PLUG`).
- **Limite di corrente** regolabile (default 2500 mA, `0` = 67 W originali), letto e
  ripristinato dal valore di fabbrica del kernel.
- **Protezione termica a due livelli**: corrente ridotta sopra `TEMP_SOFT_C`, carica
  sospesa sopra `TEMP_STOP_C` e ripresa sotto `TEMP_RESUME_C`.
- **Carica al 100% una tantum**, che si disattiva da sola al 100% o dopo
  `FORCE_FULL_EXPIRE_H` ore.
- **Carica smart**: tiene la soglia massima di notte e arriva al 100% per l'ora della
  sveglia (app Orologio) o per un orario fisso.
- **Statistiche**: campioni CSV ogni 5 minuti, consumo a schermo acceso/spento, autonomia
  stimata, cicli equivalenti e storico giornaliero della salute; esportazione su /sdcard.
- **WebUI in stile Material 3 Expressive**: anello di carica ondulato, forme che cambiano
  con lo stato, liste a segmenti, slider e interruttori Expressive, movimento a molla.
  Usa i colori dinamici del telefono su KernelSU, APatch e WebUI X, e su Magisk li ricava
  dal colore del tema Android.
- **Notifiche Android** per soglia raggiunta, pausa termica, carica smart ed emergenza.
- **Pulsante Azione** con stato e menu a tasti volume (carica al 100%, pausa).
- **`cli.sh`** per gestire tutto da terminale.
- **Sicurezza**: nessuna scrittura prima del boot completo, paracadute al 15%, wakelock
  temporaneo vicino alla soglia per evitare sforamenti in sonno profondo, boot guard che
  disattiva il modulo dopo 3 riavvii anomali di fila, ripristino dei valori originali in
  pausa, disattivazione e disinstallazione.
- Aggiornamenti dall'app root tramite `updateJson`.

[Non rilasciato]: https://github.com/zChronoX/VeuxChargeLimiter/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/zChronoX/VeuxChargeLimiter/releases/tag/v1.0.0
