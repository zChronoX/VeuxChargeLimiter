# Contribuire

Grazie per l'interesse! Segnalazioni, idee e pull request sono benvenute.

## Segnalare un problema

Apri una [issue](https://github.com/zChronoX/VeuxChargeLimiter/issues/new/choose) con il
template **Segnalazione bug** e allega:

- versione del modulo, ROM e gestore root;
- le righe del log (`/sdcard/veux_charge_limiter.log`);
- l'output di `cli.sh status` e `cli.sh probe`.

## Ambiente di sviluppo

Serve una macchina Linux (o WSL / macOS) con `bash`, `mksh`, `busybox`, `zip` e
`shellcheck`:

```sh
# Debian / Ubuntu
sudo apt install mksh busybox zip shellcheck
```

```sh
tools/test/run-tests.sh            # tutti i test, in mksh e BusyBox
tools/test/run-tests.sh mksh       # solo mksh
shellcheck -s sh module/*.sh       # lint
tools/build.sh                     # crea dist/VeuxChargeLimiter-vX.Y.Z.zip
```

Per provare la WebUI basta aprire `module/webroot/index.html` in un browser: senza root
usa dati di esempio.

## Regole per il codice

- **Gli script del modulo sono POSIX sh**: devono girare sia in **mksh** (`/system/bin/sh`
  di Android) sia in **BusyBox ash** (usata da Magisk per `action.sh` e l'installer).
  Niente `[[ ]]`, array, `local` o altre estensioni bash.
- **mksh ha interi a 32 bit**: niente calcoli con millisecondi o microampere sommati
  all'infinito.
- **Il ciclo del demone deve restare leggero**: niente processi esterni inutili a ogni
  giro (usa `rd`/`rdt` di `common.sh` per leggere i nodi).
- **Sicurezza prima di tutto**: nessuna scrittura sui nodi prima del boot completo, valori
  sempre limitati, ripristino dei default in uscita.
- Fine riga **LF** (`.gitattributes` lo impone) e ShellCheck pulito.
- Ogni nuova opzione va aggiunta in: `config.conf`, `CONF_KEYS` in `common.sh`,
  `set_defaults` in `daemon.sh`, `FIELDS` nella WebUI e la tabella nel `README.md`.
- Se cambi il comportamento del demone, aggiungi o aggiorna un test in
  `tools/test/run-tests.sh`.

## Pubblicare una nuova versione

1. Aggiorna `version` e `versionCode` in `module/module.prop`
   (`versionCode` = MAJOR×100 + MINOR×10 + PATCH, es. v1.1.0 → 110).
2. Aggiorna `update.json` con la stessa versione, lo stesso versionCode e il nuovo
   `zipUrl`.
3. In `CHANGELOG.md` sposta le voci da **[Non rilasciato]** a una nuova sezione
   `## [X.Y.Z] - AAAA-MM-GG` e aggiorna i link in fondo.
4. Controlla: `tools/build.sh --check`.
5. Commit, poi tag e push:
   ```sh
   git tag v1.1.0
   git push origin main v1.1.0
   ```
   Il workflow **Release** esegue i test, crea lo zip e pubblica la release con le note
   prese dal changelog. Da quel momento l'app root degli utenti propone l'aggiornamento.
