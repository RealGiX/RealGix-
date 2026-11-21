# Diagnosi Wi-Fi – Swisscom Internet-Box

Script che trova cosa rallenta il Wi-Fi di casa. Funziona **solo in lettura**: non modifica nessuna impostazione del router.

## iPhone (consigliato)

1. Installa l'app gratuita **a-Shell** dall'App Store.
2. Collegati al Wi-Fi di casa e apri a-Shell.
3. Scrivi questi due comandi:
   ```
   curl -L -o wifi.py https://raw.githubusercontent.com/RealGiX/RealGix-/main/wifi_diagnosi.py
   python3 wifi.py
   ```
4. Alla richiesta, inserisci la password della Internet-Box.
5. Il risultato appare subito sullo schermo. Il report completo si apre da **File → Sul mio iPhone → a-Shell**.

La prossima volta basta `python3 wifi.py`. Con iPhone la scansione delle reti vicine la fa il router stesso; il segnale del telefono viene letto dalla Internet-Box.

## Windows

## Cosa controlla

| Area | Controlli |
|---|---|
| Questo PC | segnale, banda (2.4/5 GHz), canale, standard Wi-Fi, velocità di collegamento |
| Reti vicine | quante reti usano lo stesso canale, quale canale 2.4 GHz è il meno affollato |
| Latenza | ping, jitter e pacchetti persi verso il router (Wi-Fi) e verso Internet (linea) |
| Velocità | download reale (~10 s) |
| Internet-Box | stato linea, reti attive, canali, larghezza canale, modalità 802.11b, rete ospiti, giorni senza riavvio |
| Dispositivi | chi è connesso, segnale di ognuno, dispositivi lenti o lontani, **chi sta usando banda in quel momento** |

Alla fine apre un report HTML con il **consiglio principale** in alto e tutti i problemi ordinati per gravità.

## Uso

1. Scarica la cartella sul PC (pulsante verde **Code → Download ZIP** ed estrai).
2. Collegati al Wi-Fi di casa.
3. Doppio clic su **`Avvia-Diagnosi.bat`**.
4. Quando richiesto, inserisci la password dell'interfaccia della Internet-Box (quella di `http://internetbox.home`). Puoi premere Invio per saltare: in quel caso mancheranno i dati su dispositivi e canali.

La diagnosi dura circa 2 minuti. Report (`Report-WiFi-*.html`) e dati tecnici (`Dati-WiFi-*.json`) vengono salvati nella stessa cartella.

Opzioni avanzate (da PowerShell):

```powershell
.\wifi-diagnosi.ps1 -Router 192.168.1.1 -Utente admin -Ping 60 -SenzaSpeedtest
```

## Note

- **Windows 11:** per vedere le reti vicine serve la posizione attiva (Impostazioni → Privacy e sicurezza → Posizione, con accesso per le app desktop).
- La password non viene salvata da nessuna parte.
- Il file `Dati-WiFi-*.json` contiene nomi e indirizzi MAC dei tuoi dispositivi: tienilo per te.
- Lancia lo script anche **nel momento in cui il Wi-Fi è lento**: alcuni problemi (vicini, traffico) dipendono dall'ora.
