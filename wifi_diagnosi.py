#!/usr/bin/env python3
"""
Diagnosi Wi-Fi per Swisscom Internet-Box - versione per iPhone (a-Shell) e qualsiasi Python 3.

SOLO LETTURA: non modifica nessuna impostazione del router.
Usa solo la libreria standard di Python (niente da installare).

Uso in a-Shell:
    curl -L -o wifi.py https://raw.githubusercontent.com/RealGiX/RealGix-/main/wifi_diagnosi.py
    python3 wifi.py                 # router 192.168.1.1, utente admin
    python3 wifi.py 192.168.1.1 admin
"""
import datetime
import getpass
import html
import json
import os
import re
import socket
import statistics
import sys
import time
import urllib.request

ROUTER = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.1"
UTENTE = sys.argv[2] if len(sys.argv) > 2 else "admin"
CT = "application/x-sah-ws-4-call+json"
STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M")

findings = []
dati = {"data": datetime.datetime.now().isoformat(timespec="seconds"), "router": ROUTER}


def add(livello, area, titolo, dettaglio, consiglio):
    findings.append(dict(ordine=len(findings), livello=livello, area=area,
                         titolo=titolo, dettaglio=dettaglio, consiglio=consiglio))


def step(t):
    print(f"\n>> {t}", flush=True)


def num(v):
    if v is None or isinstance(v, bool):
        return None
    try:
        return float(str(v).replace(",", "."))
    except ValueError:
        m = re.search(r"-?\d+(\.\d+)?", str(v))
        return float(m.group()) if m else None


def gi(o, *pats):
    """Valore della prima chiave che corrisponde (senza maiuscole/minuscole) a uno dei pattern."""
    if not isinstance(o, dict):
        return None
    for p in pats:
        for k, v in o.items():
            if re.fullmatch(p, k, re.I):
                return v
    return None


def band(b, ch=None):
    s = str(b or "")
    if re.search(r"2[.,]4", s):
        return "2.4 GHz"
    if re.search(r"(^|\D)6\s*G", s):
        return "6 GHz"
    if re.search(r"(^|\D)5\s*G", s):
        return "5 GHz"
    c = num(ch)
    if c:
        return "2.4 GHz" if c <= 14 else "5 GHz"
    return "?"


def norm_mac(m):
    return re.sub(r"[-:.]", "", str(m or "")).upper()


def walk(node, pred, path=""):
    out = []
    if isinstance(node, list):
        for i, x in enumerate(node):
            out += walk(x, pred, f"{path}[{i}]")
    elif isinstance(node, dict):
        if pred(node):
            out.append((path, node))
        for k, v in node.items():
            out += walk(v, pred, f"{path}/{k}")
    return out


def nome(c):
    return c.get("nome") or c.get("mac") or "?"


# ------------------------------------------------------------------ Internet-Box
class Box:
    def __init__(self, host):
        self.url = f"http://{host}/ws"
        self.ctx = None
        self.cookie = None

    def _post(self, payload, headers, timeout=15):
        body = json.dumps(payload).encode("utf-8")
        h = {"Content-Type": CT, **headers}
        req = urllib.request.Request(self.url, data=body, headers=h, method="POST")
        return urllib.request.urlopen(req, timeout=timeout)

    def call(self, service, method, params=None, auth=False, timeout=15):
        h = {"X-Requested-With": "XMLHttpRequest"}
        if auth and self.ctx:
            h["Authorization"] = f"X-Sah {self.ctx}"
            h["X-Context"] = self.ctx
            if self.cookie:
                h["Cookie"] = self.cookie
        try:
            with self._post({"service": service, "method": method, "parameters": params or {}}, h, timeout) as r:
                return json.loads(r.read().decode("utf-8", "replace"))
        except Exception:
            return None

    def login(self, user, pw):
        try:
            with self._post({"service": "sah.Device.Information", "method": "createContext",
                             "parameters": {"applicationName": "webui", "username": user, "password": pw}},
                            {"Authorization": "X-Sah-Login"}) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
                cookies = r.headers.get_all("Set-Cookie") or []
            self.ctx = (data.get("data") or {}).get("contextID")
            for c in cookies:
                m = re.match(r"\s*([^=;/\s]+)/sessid=([^;]+)", c)
                if m and self.ctx:
                    d, s = m.groups()
                    self.cookie = f"{d}/context={self.ctx}; swc/deviceID={d}; {d}/sessid={s}"
                    break
        except Exception:
            self.ctx = None
        return bool(self.ctx)


# ------------------------------------------------------------------ misure di rete
def tcp_latency(host, port, n=20):
    t, persi = [], 0
    for _ in range(n):
        s = time.perf_counter()
        try:
            c = socket.create_connection((host, port), timeout=2)
            t.append((time.perf_counter() - s) * 1000)
            c.close()
        except OSError:
            persi += 1
        time.sleep(0.25)
    r = {"destinazione": f"{host}:{port}", "inviati": n, "persi_pct": round(100 * persi / n, 1),
         "media_ms": None, "max_ms": None, "jitter_ms": None}
    if t:
        r["media_ms"] = round(statistics.mean(t), 1)
        r["max_ms"] = round(max(t), 1)
        if len(t) > 1:
            r["jitter_ms"] = round(statistics.mean(abs(a - b) for a, b in zip(t[1:], t[:-1])), 1)
    return r


def speedtest(secondi=8):
    try:
        req = urllib.request.Request("https://speed.cloudflare.com/__down?bytes=200000000",
                                     headers={"User-Agent": "wifi-diagnosi"})
        tot, s = 0, time.perf_counter()
        with urllib.request.urlopen(req, timeout=10) as r:
            while time.perf_counter() - s < secondi:
                b = r.read(262144)
                if not b:
                    break
                tot += len(b)
        el = time.perf_counter() - s
        return round(tot * 8 / 1e6 / el, 1) if el > 0 else None
    except Exception as e:
        print(f"   Speedtest non riuscito: {e}")
        return None


def mio_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((ROUTER, 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


# ================================================================== main
print("=" * 46)
print("  Diagnosi Wi-Fi - Swisscom Internet-Box")
print("  (solo lettura, nessuna impostazione modificata)")
print("=" * 46)

ip_tel = mio_ip()
print(f"   IP di questo telefono: {ip_tel}  |  Router: {ROUTER}")

# --- Latenza
step("Ritardo verso il router (circa 10 secondi)")
pR = tcp_latency(ROUTER, 80)
print(f"   Media {pR['media_ms']} ms | Max {pR['max_ms']} ms | Jitter {pR['jitter_ms']} ms | Persi {pR['persi_pct']}%")
step("Ritardo verso Internet (circa 10 secondi)")
pI = tcp_latency("1.1.1.1", 443)
print(f"   Media {pI['media_ms']} ms | Max {pI['max_ms']} ms | Jitter {pI['jitter_ms']} ms | Persi {pI['persi_pct']}%")
dati["latenza"] = [pR, pI]

if pR["media_ms"] is None:
    add(2, "Latenza", "Il router non risponde", "Impossibile misurare il Wi-Fi tra telefono e router.",
        "Controlla di essere sul Wi-Fi di casa e che l'indirizzo del router sia giusto (es. python3 wifi.py 192.168.1.1).")
elif pR["persi_pct"] > 5 or pR["media_ms"] > 40:
    add(3, "Latenza", f"Wi-Fi instabile verso il router (media {pR['media_ms']} ms, persi {pR['persi_pct']}%)",
        "Verso il router dovrebbero bastare pochi millisecondi e 0% di persi: il problema è il Wi-Fi in casa, non la linea Swisscom.",
        "Tipico di segnale debole, canale affollato o interferenze: guarda gli altri punti del report.")
elif pR["persi_pct"] > 1 or pR["media_ms"] > 15 or (pR["jitter_ms"] or 0) > 15:
    add(2, "Latenza", f"Wi-Fi verso il router non ottimale (media {pR['media_ms']} ms, jitter {pR['jitter_ms']} ms)",
        "Ci sono ritardi o picchi nel Wi-Fi di casa: si sentono in videochiamate e giochi.",
        "Controlla segnale, banda e affollamento del canale (vedi sotto).")
if pR["media_ms"] is not None and pR["persi_pct"] <= 1 and pR["media_ms"] <= 15:
    if pI["media_ms"] is None:
        add(3, "Linea Internet", "Internet non risponde", "Il router risponde ma Internet no.",
            "Controlla lo stato della linea nella Internet-Box o chiama Swisscom.")
    elif pI["persi_pct"] > 2 or pI["media_ms"] > 60 or (pI["jitter_ms"] or 0) > 25:
        add(2, "Linea Internet", f"Ritardo alto verso Internet (media {pI['media_ms']} ms) mentre il Wi-Fi è a posto",
            "Il rallentamento è oltre il router: linea, rete Swisscom o qualcuno in casa che satura la banda.",
            "Guarda chi sta usando banda nella tabella dispositivi; se nessuno, segnala a Swisscom.")

# --- Speedtest
step("Test di velocità in download (circa 8 secondi)")
speed = speedtest()
print(f"   Download: {speed} Mbps")
dati["download_mbps"] = speed

# --- Router
step(f"Connessione alla Internet-Box ({ROUTER})")
box = Box(ROUTER)
info = (box.call("DeviceInfo", "get") or {}).get("status")
clienti, aps, tel = [], [], None
if not info:
    print("   La Internet-Box non risponde.")
    add(0, "Router", "Impossibile leggere i dati della Internet-Box", f"Nessuna risposta da {box.url}.",
        "Verifica di essere sul Wi-Fi di casa. Se il router ha un altro indirizzo: python3 wifi.py <indirizzo>.")
else:
    up_g = round((num(info.get("UpTime")) or 0) / 86400, 1)
    print(f"   {info.get('Manufacturer', '')} {info.get('ModelName', '')} - firmware {info.get('SoftwareVersion', '')} - acceso da {up_g} giorni")
    dati["box"] = {"modello": info.get("ModelName"), "firmware": info.get("SoftwareVersion"), "acceso_giorni": up_g}
    if up_g > 60:
        add(1, "Router", f"Il router è acceso da {up_g} giorni senza riavvio",
            "Dopo molte settimane alcuni router accumulano rallentamenti.",
            "Riavvia la Internet-Box (staccala 30 secondi): è un test gratuito.")
    wan = (box.call("NMC", "getWANStatus") or {}).get("data") or {}
    dati["box"]["linea"] = wan
    if wan and wan.get("LinkState") != "up":
        add(3, "Linea Internet", f"Linea Internet non attiva ({wan.get('LinkState')})", "Il router segnala la linea giù.",
            "Controlla i cavi e lo stato su swisscom.ch o chiama il supporto.")

    try:
        pw = getpass.getpass(f"   Password della Internet-Box (utente '{UTENTE}', Invio per saltare): ")
    except Exception:
        pw = input(f"   Password della Internet-Box (utente '{UTENTE}', Invio per saltare): ")
    if pw and box.login(UTENTE, pw):
        print("   Accesso riuscito.")
    elif pw:
        print("   Accesso non riuscito (password errata?). Continuo con i dati pubblici.")
        add(0, "Router", "Accesso alla Internet-Box non riuscito", "Senza accesso non si vedono dispositivi e canali.",
            "Rilancia con la password dell'interfaccia web (quella di http://internetbox.home).")
    pw = None

    wifi = (box.call("NMC.Wifi", "get", auth=True) or {}).get("data") or {}
    dati["box"]["wifi"] = wifi
    if wifi.get("Scheduler") is True:
        add(1, "Router", "È attiva una programmazione oraria del Wi-Fi", "Il Wi-Fi si spegne o si limita in certi orari.",
            "Se il Wi-Fi sparisce sempre alla stessa ora, controlla la programmazione nella Internet-Box.")

    if box.ctx:
        # Reti Wi-Fi del router
        for a in (box.call("Devices", "get", {"expression": "lan and vap"}, auth=True) or {}).get("status") or []:
            aps.append({"chiave": a.get("Key", ""), "ssid": a.get("SSID", ""), "bssid": norm_mac(a.get("BSSID")),
                        "attiva": a.get("Enabled"), "banda": band(a.get("OperatingFrequencyBand"), a.get("Channel")),
                        "canale": num(a.get("Channel")), "standard": a.get("OperatingStandards", ""),
                        "ospiti": "guest" in str(a.get("Key", "")).lower()})
        dati["box"]["reti"] = aps
        miei_ssid = {a["ssid"] for a in aps if a["ssid"]}
        miei_bssid = {a["bssid"] for a in aps if a["bssid"]}

        # Radio e client associati
        mib = box.call("NeMo.Intf.lan", "getMIBs", {"mibs": "wlanradio wlanvap"}, auth=True)
        dati["box"]["mib"] = mib
        radios, radio_keys = [], []
        for path, o in walk(mib, lambda o: "Channel" in o and "OperatingFrequencyBand" in o):
            m = re.search(r"wlanradio/([^/\[]+)$", path)
            if not m:
                continue
            radio_keys.append(m.group(1))
            radios.append({"intf": m.group(1), "banda": band(o.get("OperatingFrequencyBand"), o.get("Channel")),
                           "canale": num(o.get("Channel")),
                           "larghezza": str(o.get("CurrentOperatingChannelBandwidth") or o.get("OperatingChannelBandwidth") or ""),
                           "auto": o.get("AutoChannelEnable")})
        dati["box"]["radio"] = radios

        def assoc_list(m):
            res = []
            for path, o in walk(m, lambda o: "MACAddress" in o and ("SignalStrength" in o or "LastDataDownlinkRate" in o)):
                vm = re.search(r"wlanvap/([^/\[]+)", path)
                tx, rx = num(o.get("TxBytes")), num(o.get("RxBytes"))
                res.append({"mac": norm_mac(o.get("MACAddress")), "vap": vm.group(1) if vm else "",
                            "segnale": num(o.get("SignalStrength")), "snr": num(o.get("SignalNoiseRatio")),
                            "down": num(o.get("LastDataDownlinkRate")), "standard": o.get("OperatingStandard"),
                            "bytes": (tx or 0) + (rx or 0) if (tx is not None or rx is not None) else None})
            return res

        assoc = assoc_list(mib)
        traffico = {}
        if any(a["bytes"] is not None for a in assoc):
            step("Misuro chi sta usando banda adesso (10 secondi)")
            t0 = time.time()
            time.sleep(10)
            a2 = {a["mac"]: a for a in assoc_list(box.call("NeMo.Intf.lan", "getMIBs", {"mibs": "wlanvap"}, auth=True))}
            secs = time.time() - t0
            for a in assoc:
                b = a2.get(a["mac"])
                if b and a["bytes"] is not None and b["bytes"] is not None and b["bytes"] >= a["bytes"]:
                    traffico[a["mac"]] = round((b["bytes"] - a["bytes"]) * 8 / 1e6 / secs, 2)
        max_rate = max([a["down"] for a in assoc if a["down"]] or [0])
        div = 1000 if max_rate > 10000 else 1  # alcuni firmware danno kbps

        # Dispositivi
        ap_band = {a["chiave"]: a["banda"] for a in aps if a["chiave"]}
        by_mac = {a["mac"]: a for a in assoc}
        visti = set()
        for d in (box.call("Devices", "get", {"expression": "lan and not self"}, auth=True) or {}).get("status") or []:
            mac = norm_mac(d.get("PhysAddress"))
            a = by_mac.get(mac)
            l2 = str(d.get("Layer2Interface") or "")
            is_wifi = l2 in ap_band or bool(re.match(r"wl|wifi|vap", l2, re.I)) or a is not None or d.get("SignalStrength") is not None
            sig = a["segnale"] if a and a["segnale"] is not None else num(d.get("SignalStrength"))
            if sig is not None and sig > 0:
                sig = -sig
            b = ap_band.get(l2) or (ap_band.get(a["vap"]) if a else None) or ("?" if is_wifi else "Cavo")
            clienti.append({"nome": d.get("Name", ""), "ip": d.get("IPAddress", ""), "mac": mac,
                            "produttore": d.get("MACVendor", ""), "attivo": bool(d.get("Active")), "wifi": is_wifi,
                            "banda": b, "segnale": sig,
                            "link": round(a["down"] / div) if a and a["down"] else None,
                            "traffico": traffico.get(mac)})
            visti.add(mac)
        for a in assoc:
            if a["mac"] in visti:
                continue
            sig = -a["segnale"] if a["segnale"] and a["segnale"] > 0 else a["segnale"]
            clienti.append({"nome": "", "ip": "", "mac": a["mac"], "produttore": "", "attivo": True, "wifi": True,
                            "banda": ap_band.get(a["vap"], "?"), "segnale": sig,
                            "link": round(a["down"] / div) if a["down"] else None, "traffico": traffico.get(a["mac"])})
        dati["box"]["dispositivi"] = clienti
        attivi = [c for c in clienti if c["attivo"]]
        wifi_attivi = [c for c in attivi if c["wifi"]]
        print(f"   Dispositivi attivi: {len(attivi)} (di cui {len(wifi_attivi)} in Wi-Fi)")

        # Questo iPhone visto dal router
        tel = next((c for c in clienti if ip_tel and c["ip"] == ip_tel), None)
        if tel:
            tel["nome"] = (tel["nome"] or "") + " (questo telefono)"
            print(f"   Questo telefono: banda {tel['banda']}, segnale {tel['segnale']} dBm, collegamento {tel['link']} Mbps")
            if tel["segnale"] is not None and tel["segnale"] < -75:
                add(3, "Questo telefono", f"Segnale molto debole sul telefono ({tel['segnale']} dBm)",
                    "Con questo segnale la velocità crolla e i pacchetti vanno ripetuti.",
                    "Avvicinati al router o spostalo in posizione centrale e rialzata, lontano da muri spessi e metallo. Per case grandi valuta un ripetitore mesh (es. Swisscom WLAN-Box).")
            elif tel["segnale"] is not None and tel["segnale"] < -67:
                add(2, "Questo telefono", f"Segnale debole sul telefono ({tel['segnale']} dBm)",
                    "Sufficiente per navigare ma la velocità reale è ridotta.",
                    "Riduci gli ostacoli tra telefono e router.")
            if tel["banda"] == "2.4 GHz":
                add(2, "Questo telefono", "Il telefono è sulla banda 2.4 GHz",
                    "La 2.4 GHz è più lenta e disturbata; la 5 GHz è in genere molto più veloce a breve/media distanza.",
                    "Vicino al router dovrebbe usare la 5 GHz: dai un nome diverso alla rete 5 GHz nella Internet-Box e collegati a quella.")

        # Scansione reti vicine fatta dal router
        step("Il router scansiona le reti vicine (fino a 30 secondi)")
        vicine, spettro = [], []
        for r in radio_keys:
            sp = box.call(f"NeMo.Intf.{r}", "getSpectrumInfo", {"update": True}, auth=True, timeout=30)
            sc = box.call(f"NeMo.Intf.{r}", "getScanResults", {}, auth=True, timeout=30)
            dati["box"].setdefault("scan_raw", {})[r] = {"spectrum": sp, "scan": sc}
            rb = next((x["banda"] for x in radios if x["intf"] == r), "?")
            for _, o in walk(sp, lambda o: gi(o, "channel") is not None and len(o) > 1):
                spettro.append({"banda": band(None, gi(o, "channel")) if rb == "?" else rb, "canale": num(gi(o, "channel")),
                                "libero_pct": num(gi(o, "availability", "available.*")),
                                "rumore": num(gi(o, "noise.*")), "n_ap": num(gi(o, "accesspoints", "nbr.*", "numberofaccesspoints"))})
            for _, o in walk(sc, lambda o: gi(o, "bssid") is not None and gi(o, "channel") is not None):
                bssid = norm_mac(gi(o, "bssid"))
                sig = num(gi(o, "signalstrength", "rssi", "signal.*"))
                vicine.append({"ssid": gi(o, "ssid") or "", "bssid": bssid, "canale": num(gi(o, "channel")),
                               "banda": band(gi(o, "operatingfrequencyband", "band"), gi(o, "channel")),
                               "segnale": -abs(sig) if sig else None,
                               "mia": bssid in miei_bssid or (gi(o, "ssid") or "") in miei_ssid})
        dati["box"]["vicine"], dati["box"]["spettro"] = vicine, spettro
        altre = [v for v in vicine if not v["mia"]]
        print(f"   Reti vicine viste dal router: {len(altre)}")
        if not vicine and not spettro:
            add(0, "Reti vicine", "Il router non ha fornito la scansione delle reti vicine",
                "Il firmware non espone questi dati o usa nomi diversi.",
                "Manda il file Dati-WiFi-*.json a chi mantiene lo script per adattarlo al tuo modello.")

        def peso(v):  # dBm -> peso: -40 forte (60), -90 debole (10)
            s = v["segnale"] if v["segnale"] is not None else -80
            return max(5, min(100, s + 100))

        def score24(ch):
            return sum(peso(v) for v in altre if v["banda"] == "2.4 GHz" and v["canale"] and abs(v["canale"] - ch) < 5)

        sc24 = {c: score24(c) for c in (1, 6, 11)}
        best24 = min(sc24, key=sc24.get)
        dati["box"]["punteggio24"] = sc24

        # --- Analisi router
        r24 = [a for a in aps if a["banda"] == "2.4 GHz" and not a["ospiti"]]
        r5 = [a for a in aps if a["banda"] == "5 GHz" and not a["ospiti"]]
        if r5 and not any(a["attiva"] for a in r5):
            add(3, "Router", "La rete Wi-Fi a 5 GHz è spenta", "Tutti i dispositivi sono costretti sulla 2.4 GHz, più lenta.",
                "Attiva la 5 GHz nelle impostazioni Wi-Fi della Internet-Box.")
        for a in r24:
            if re.search(r"(^|,)\s*b\s*(,|$)", str(a["standard"])):
                add(2, "Router", f"Modalità di compatibilità 802.11b attiva sulla 2.4 GHz ({a['standard']})",
                    "Un solo dispositivo vecchissimo in 802.11b rallenta tutta la 2.4 GHz.",
                    "Imposta la modalità g/n/ax nelle impostazioni Wi-Fi avanzate.")
                break
        if any(a["ospiti"] and a["attiva"] for a in aps):
            add(1, "Router", "La rete ospiti è attiva", "Ogni rete in più occupa un po' di tempo radio anche se nessuno la usa.",
                "Spegnila quando non hai ospiti.")

        ch24 = next((a["canale"] for a in r24 if a["attiva"] and a["canale"]), None)
        if ch24 and altre:
            cur = score24(ch24)
            if int(ch24) not in (1, 6, 11):
                add(2, "Canali", f"Il router usa il canale 2.4 GHz {int(ch24)} (non è 1, 6 o 11)",
                    "I canali intermedi si sovrappongono a due gruppi di vicini insieme.",
                    f"Imposta manualmente il canale {best24}, il meno affollato ora.")
            elif cur > 100 and cur > 1.5 * sc24[best24] and int(ch24) != best24:
                add(2, "Canali", f"Canale 2.4 GHz {int(ch24)} affollato dalle reti vicine",
                    f"Affollamento: canale {int(ch24)} = {cur}, canale {best24} = {sc24[best24]} (più basso è meglio).",
                    f"Nella Internet-Box imposta il canale 2.4 GHz su {best24}. Ripeti il test la sera, quando i vicini usano di più la rete.")
        ch5 = next((a["canale"] for a in r5 if a["attiva"] and a["canale"]), None)
        if ch5:
            sovr = [v for v in altre if v["banda"] == "5 GHz" and v["canale"] and abs(v["canale"] - ch5) < 8
                    and (v["segnale"] or -100) > -75]
            if len(sovr) >= 3:
                add(2, "Canali", f"Canale 5 GHz {int(ch5)} condiviso con {len(sovr)} reti vicine forti",
                    "Le reti sullo stesso blocco di canali si dividono il tempo di trasmissione.",
                    "Prova un altro gruppo di canali a 5 GHz (36-48 oppure 100-128).")
        for ch, bnd in ((ch24, "2.4 GHz"), (ch5, "5 GHz")):
            s = next((x for x in spettro if x["canale"] == ch and x["banda"] == bnd and x["libero_pct"] is not None), None)
            if s and s["libero_pct"] < 50:
                add(3 if s["libero_pct"] < 30 else 2, "Canali",
                    f"Il canale {bnd} {int(ch)} è libero solo il {int(s['libero_pct'])}% del tempo",
                    "Il router misura che il canale è occupato gran parte del tempo da altre reti o interferenze.",
                    f"Nella Internet-Box imposta il canale 2.4 GHz su {best24}." if bnd == "2.4 GHz"
                    else "Nella Internet-Box cambia canale 5 GHz (prova 36-48 oppure 100-128).")
        for r in radios:
            if r["banda"] == "5 GHz" and re.match(r"\s*20", r["larghezza"]):
                add(2, "Canali", "La rete 5 GHz usa canali larghi solo 20 MHz",
                    "Con 20 MHz la velocità massima è circa un quarto rispetto a 80 MHz.",
                    "Imposta la larghezza 5 GHz su 80 MHz o Auto.")
            if r["banda"] == "2.4 GHz" and re.match(r"\s*40", r["larghezza"]) and len(altre) > 5:
                add(1, "Canali", "La 2.4 GHz usa canali da 40 MHz in una zona affollata",
                    "In 2.4 GHz i 40 MHz si sovrappongono a quasi tutti i vicini.",
                    "Imposta la larghezza 2.4 GHz a 20 MHz: spesso diventa più stabile.")

        if len(wifi_attivi) > 25:
            add(2, "Dispositivi", f"Molti dispositivi Wi-Fi attivi ({len(wifi_attivi)})",
                "Il tempo radio è condiviso tra tutti.", "Collega via cavo quello che puoi (TV, console, PC fissi).")
        deboli = [c for c in wifi_attivi if c["segnale"] is not None and c["segnale"] < -75 and c is not tel]
        if deboli:
            add(2, "Dispositivi", f"{len(deboli)} dispositivi con segnale debole",
                "Un dispositivo lontano trasmette lentamente e occupa la radio più a lungo, rallentando tutti. "
                "Dispositivi: " + ", ".join(f"{nome(c)} ({int(c['segnale'])} dBm)" for c in deboli),
                "Avvicinali al router, collegali via cavo o aggiungi un punto mesh in quella zona.")
        lenti = [c for c in wifi_attivi if c["link"] and c["link"] < 20]
        if lenti:
            add(1, "Dispositivi", f"{len(lenti)} dispositivi collegati a velocità molto bassa",
                "Dispositivi: " + ", ".join(f"{nome(c)} ({c['link']} Mbps)" for c in lenti),
                "Spesso sono prese smart, telecamere o dispositivi lontani: avvicinali o sostituiscili.")
        su24 = [c for c in wifi_attivi if c["banda"] == "2.4 GHz"]
        if r5 and len(wifi_attivi) >= 4 and len(su24) > 0.7 * len(wifi_attivi):
            add(1, "Dispositivi", f"{len(su24)} dispositivi su {len(wifi_attivi)} sono sulla 2.4 GHz",
                "La 2.4 GHz è la banda più lenta.", "Telefoni, PC e TV recenti dovrebbero stare sulla 5 GHz.")
        pesanti = sorted([c for c in clienti if c["traffico"] and c["traffico"] >= 5], key=lambda c: -c["traffico"])
        if pesanti:
            add(2, "Traffico", "Dispositivi che stanno usando molta banda adesso",
                "Durante il test: " + ", ".join(f"{nome(c)} ({c['traffico']} Mbps)" for c in pesanti)
                + ". Download, aggiornamenti, streaming 4K o backup rallentano tutti gli altri.",
                "Se non è voluto, controlla quel dispositivo (aggiornamenti automatici, backup, torrent).")

if speed is not None and tel and tel.get("link") and pR["media_ms"] is not None and pR["media_ms"] <= 15:
    if speed < 0.25 * tel["link"] and speed < 100:
        add(1, "Velocità", f"Download di {speed} Mbps, molto sotto il collegamento Wi-Fi ({tel['link']} Mbps)",
            "Il Wi-Fi potrebbe andare più veloce: il limite è altrove (abbonamento, linea o altri che scaricano).",
            "Confronta con la velocità del tuo abbonamento Swisscom.")

# ------------------------------------------------------------------ report
LAB = {3: "ALTO", 2: "MEDIO", 1: "BASSO", 0: "INFO"}
COL = {3: "#d32f2f", 2: "#f57c00", 1: "#c9a800", 0: "#607d8b"}
ordinati = sorted(findings, key=lambda f: (-f["livello"], f["ordine"]))
problemi = [f for f in ordinati if f["livello"] >= 1]
E = lambda s: html.escape("" if s is None else str(s))

print("\n" + "=" * 46)
if problemi:
    top = problemi[0]
    print("CONSIGLIO PRINCIPALE:")
    print(f"  [{LAB[top['livello']]}] {top['titolo']}")
    print(f"  Cosa fare: {top['consiglio']}")
    print(f"\nTutti i problemi ({len(problemi)}):")
    for f in problemi:
        print(f"  [{LAB[f['livello']]}] {f['titolo']}")
else:
    print("Nessun problema evidente trovato.")

p = []
p.append(f"""<!DOCTYPE html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Diagnosi Wi-Fi {STAMP}</title>
<style>body{{font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:900px;margin:16px auto;padding:0 12px;color:#222;background:#fafafa}}
h2{{margin-top:28px;border-bottom:2px solid #ddd;padding-bottom:4px}}.top{{background:#fff;border-left:6px solid #1976d2;padding:14px;border-radius:6px;box-shadow:0 1px 3px #0002}}
.f{{background:#fff;padding:10px 14px;margin:10px 0;border-radius:6px;box-shadow:0 1px 2px #0002;border-left:6px solid #999}}
.tag{{display:inline-block;color:#fff;font-size:12px;font-weight:bold;padding:2px 8px;border-radius:10px;margin-right:6px}}
.area{{color:#777;font-size:13px}}.c{{margin-top:6px}}.c b{{color:#1976d2}}.muted{{color:#888;font-size:13px}}
.tw{{overflow-x:auto}}table{{border-collapse:collapse;width:100%;background:#fff;font-size:13px}}th,td{{border:1px solid #ddd;padding:4px 6px;text-align:left}}th{{background:#eee}}
</style></head><body><h1>Diagnosi Wi-Fi</h1><div class="muted">{E(datetime.datetime.now().strftime('%d.%m.%Y %H:%M'))} - Router {E(ROUTER)}</div>
<h2>Consiglio principale</h2><div class="top">""")
if problemi:
    t = problemi[0]
    p.append(f"<span class='tag' style='background:{COL[t['livello']]}'>{LAB[t['livello']]}</span><b>{E(t['titolo'])}</b>"
             f"<div class='c'><b>Cosa fare:</b> {E(t['consiglio'])}</div><div class='muted'>Perché: {E(t['dettaglio'])}</div>")
else:
    p.append("<b>Nessun problema evidente.</b> Se il Wi-Fi è lento solo a volte, rilancia lo script proprio in quel momento.")
p.append(f"</div><h2>Tutti i punti ({len(problemi)} problemi)</h2>")
for f in ordinati:
    p.append(f"<div class='f' style='border-left-color:{COL[f['livello']]}'><span class='tag' style='background:{COL[f['livello']]}'>{LAB[f['livello']]}</span>"
             f"<span class='area'>{E(f['area'])}</span><div><b>{E(f['titolo'])}</b></div><div>{E(f['dettaglio'])}</div>"
             f"<div class='c'><b>Cosa fare:</b> {E(f['consiglio'])}</div></div>")
p.append("<h2>Ritardi e velocità</h2><div class='tw'><table><tr><th>Destinazione</th><th>Media ms</th><th>Max ms</th><th>Jitter ms</th><th>Persi %</th></tr>")
for r in (pR, pI):
    p.append(f"<tr><td>{E(r['destinazione'])}</td><td>{E(r['media_ms'])}</td><td>{E(r['max_ms'])}</td><td>{E(r['jitter_ms'])}</td><td>{E(r['persi_pct'])}</td></tr>")
p.append(f"</table></div><p>Download: <b>{E(speed) + ' Mbps' if speed is not None else 'non misurato'}</b></p>")
if "box" in dati:
    b = dati["box"]
    p.append(f"<h2>Internet-Box</h2><p>{E(b.get('modello'))} - firmware {E(b.get('firmware'))} - acceso da {E(b.get('acceso_giorni'))} giorni</p>")
    if aps:
        p.append("<div class='tw'><table><tr><th>Rete</th><th>Banda</th><th>Canale</th><th>Standard</th><th>Attiva</th></tr>")
        for a in aps:
            p.append(f"<tr><td>{E(a['ssid'])}{' (ospiti)' if a['ospiti'] else ''}</td><td>{E(a['banda'])}</td><td>{E(int(a['canale']) if a['canale'] else '')}</td><td>{E(a['standard'])}</td><td>{E(a['attiva'])}</td></tr>")
        p.append("</table></div>")
    att = sorted([c for c in clienti if c["attivo"]], key=lambda c: (-(c["traffico"] or 0), str(c["nome"])))
    if att:
        p.append("<h2>Dispositivi attivi</h2><div class='tw'><table><tr><th>Nome</th><th>IP</th><th>Collegamento</th><th>Segnale dBm</th><th>Link Mbps</th><th>Traffico ora Mbps</th><th>Produttore</th></tr>")
        for c in att:
            st = " style='color:#d32f2f;font-weight:bold'" if c["segnale"] is not None and c["segnale"] < -75 else ""
            p.append(f"<tr><td>{E(c['nome'] or c['mac'])}</td><td>{E(c['ip'])}</td><td>{E(c['banda'])}</td><td{st}>{E(int(c['segnale']) if c['segnale'] is not None else '')}</td>"
                     f"<td>{E(c['link'])}</td><td>{E(c['traffico'])}</td><td>{E(c['produttore'])}</td></tr>")
        p.append("</table></div><p class='muted'>Segnale: oltre -60 dBm ottimo, -60/-70 buono, -70/-75 scarso, sotto -75 debole.</p>")
    vic = b.get("vicine") or []
    if vic:
        sc = b.get("punteggio24", {})
        p.append(f"<h2>Reti vicine (viste dal router)</h2><p>Affollamento 2.4 GHz (più basso è meglio): canale 1 = {sc.get(1)}, 6 = {sc.get(6)}, 11 = {sc.get(11)}.</p>")
        p.append("<div class='tw'><table><tr><th>Rete</th><th>Banda</th><th>Canale</th><th>Segnale dBm</th></tr>")
        for v in sorted(vic, key=lambda v: (v["banda"], v["canale"] or 0, v["segnale"] or -100)):
            p.append(f"<tr><td>{E(v['ssid'])}{' <b>(tua)</b>' if v['mia'] else ''}</td><td>{E(v['banda'])}</td><td>{E(int(v['canale']) if v['canale'] else '')}</td><td>{E(v['segnale'])}</td></tr>")
        p.append("</table></div>")
p.append("<p class='muted'>Creato da wifi_diagnosi.py - nessuna impostazione del router è stata modificata.</p></body></html>")

html_path = os.path.abspath(f"Report-WiFi-{STAMP}.html")
json_path = os.path.abspath(f"Dati-WiFi-{STAMP}.json")
with open(html_path, "w", encoding="utf-8") as fh:
    fh.write("".join(p))
with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(dati, fh, ensure_ascii=False, indent=1, default=str)
print(f"\nReport: {os.path.basename(html_path)}")
print(f"Dati tecnici: {os.path.basename(json_path)}")
print("Apri il report da: app File > Sul mio iPhone > a-Shell")
