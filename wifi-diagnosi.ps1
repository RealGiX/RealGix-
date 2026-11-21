#requires -Version 5.1
<#
  Diagnosi Wi-Fi per Swisscom Internet-Box
  ----------------------------------------
  Cosa fa (SOLO LETTURA: non cambia nessuna impostazione del router):
    1. Analizza la connessione Wi-Fi di questo PC (segnale, banda, canale, velocità).
    2. Scansiona le reti Wi-Fi vicine e misura l'affollamento dei canali.
    3. Misura latenza, jitter e pacchetti persi verso il router e verso Internet.
    4. Misura la velocità di download.
    5. Si collega alla Internet-Box e legge: stato linea, reti Wi-Fi, canali,
       dispositivi connessi, qualità del segnale di ciascuno e traffico in corso.
  Alla fine crea un report HTML e lo apre nel browser.

  Uso: doppio clic su "Avvia-Diagnosi.bat"
   oppure: powershell -ExecutionPolicy Bypass -File .\wifi-diagnosi.ps1 [-Router 192.168.1.1] [-Utente admin] [-Ping 30]
#>
param(
    [string]$Router = "",
    [string]$Utente = "admin",
    [int]$Ping = 30,
    [switch]$SenzaSpeedtest
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Cartella = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$Dati = [ordered]@{ Data = (Get-Date).ToString('s') }

# ---------------------------------------------------------------- helper
$script:Findings = New-Object System.Collections.ArrayList
function Add-Finding([int]$Livello, [string]$Area, [string]$Titolo, [string]$Dettaglio, [string]$Consiglio) {
    [void]$script:Findings.Add([pscustomobject]@{
        Ordine = $script:Findings.Count; Livello = $Livello; Area = $Area
        Titolo = $Titolo; Dettaglio = $Dettaglio; Consiglio = $Consiglio
    })
}
function P($o, [string]$n) {
    if ($null -eq $o) { return $null }
    $p = $o.PSObject.Properties[$n]
    if ($p) { return $p.Value }
    return $null
}
function Step([string]$t) { Write-Host ""; Write-Host ">> $t" -ForegroundColor Cyan }
function ToNum($v) {
    if ($null -eq $v) { return $null }
    $s = "$v" -replace ',', '.'
    $d = 0.0
    if ([double]::TryParse(($s -replace '[^\d\.\-]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}
function Norm-Band($b, $ch) {
    $s = "$b"
    if ($s -match '2[\.,]4') { return '2.4 GHz' }
    if ($s -match '(^|\D)6\s*G') { return '6 GHz' }
    if ($s -match '(^|\D)5\s*G') { return '5 GHz' }
    $c = ToNum $ch
    if ($c) { if ($c -le 14) { return '2.4 GHz' } else { return '5 GHz' } }
    return '?'
}
function Find-Objects($node, [scriptblock]$Pred, [string]$Path = '') {
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $node) { return ,$out }
    if ($node -is [System.Array]) {
        $i = 0
        foreach ($x in $node) { foreach ($r in (Find-Objects $x $Pred "$Path[$i]")) { [void]$out.Add($r) }; $i++ }
    } elseif ($node -is [System.Management.Automation.PSCustomObject]) {
        if (& $Pred $node) { [void]$out.Add([pscustomobject]@{ Path = $Path; Obj = $node }) }
        foreach ($p in $node.PSObject.Properties) {
            foreach ($r in (Find-Objects $p.Value $Pred "$Path/$($p.Name)")) { [void]$out.Add($r) }
        }
    }
    return ,$out
}
function NormMac($m) { if ($m) { return ("$m" -replace '[-:\.]', '').ToUpper() } return '' }

# Etichette di netsh in varie lingue di Windows (italiano, inglese, tedesco, francese, spagnolo)
$reSSID    = 'SSID'
$reSignal  = 'Signal|Segnale|Se.al'
$reChannel = 'Channel|Canale|Kanal|Canal'
$reBand    = 'Band|Banda|Frequenzband|Bande'
$reRadio   = 'Radio type|Tipo frequenza radio|Tipo di radio|Tipo radio|Funktyp|Type de radio|Tipo de radio'
$reRx      = 'Receive rate|Velocit. ricezione|Velocit. di ricezione|Empfangsrate|D.bit de r.ception|Velocidad de recepci.n'
$reTx      = 'Transmit rate|Velocit. trasmissione|Velocit. di trasmissione|.bertragungsrate|Senderate|D.bit de transmission|Velocidad de transmisi.n'
$reUtil    = 'Channel Utilization|Utilizzo (?:del )?canale|Kanalauslastung|Utilisation du canal|Utilizaci.n del canal'

function Get-NetshValue($lines, [string]$pattern, [switch]$Loose) {
    $re = if ($Loose) { "^\s*($pattern)[^:]*:\s*(.+)$" } else { "^\s*($pattern)\s*:\s*(.+)$" }
    foreach ($l in $lines) { if ($l -match $re) { return $Matches[2].Trim() } }
    return $null
}

Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Diagnosi Wi-Fi - Swisscom Internet-Box" -ForegroundColor Green
Write-Host "  (solo lettura, nessuna impostazione viene modificata)" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green

# ---------------------------------------------------------------- 1. Wi-Fi di questo PC
Step "Analisi della connessione Wi-Fi di questo PC"
$ifLines = @(netsh wlan show interfaces 2>$null)
$pc = [ordered]@{
    SSID = Get-NetshValue $ifLines $reSSID
    SegnalePct = ToNum (Get-NetshValue $ifLines $reSignal)
    Canale = ToNum (Get-NetshValue $ifLines $reChannel)
    Banda = Get-NetshValue $ifLines $reBand
    TipoRadio = Get-NetshValue $ifLines $reRadio
    RxMbps = ToNum (Get-NetshValue $ifLines $reRx -Loose)
    TxMbps = ToNum (Get-NetshValue $ifLines $reTx -Loose)
}
$pc.Banda = Norm-Band $pc.Banda $pc.Canale
$suWifi = [bool]$pc.SSID
if ($suWifi) {
    $pc.SegnaleDbmStimato = if ($pc.SegnalePct -ne $null) { [int]($pc.SegnalePct / 2 - 100) } else { $null }
    Write-Host ("   Rete: {0} | Segnale: {1}% | Banda: {2} | Canale: {3} | {4} | Rx {5} / Tx {6} Mbps" -f $pc.SSID, $pc.SegnalePct, $pc.Banda, $pc.Canale, $pc.TipoRadio, $pc.RxMbps, $pc.TxMbps)

    if ($pc.SegnalePct -ne $null) {
        if ($pc.SegnalePct -lt 40) {
            Add-Finding 3 'Questo PC' "Segnale Wi-Fi molto debole ($($pc.SegnalePct)%, circa $($pc.SegnaleDbmStimato) dBm)" `
                'Con un segnale così il router deve abbassare molto la velocità e ripetere spesso i pacchetti.' `
                'Avvicinati al router o spostalo in posizione centrale e rialzata, lontano da muri spessi, metallo, acquari e microonde. Se la casa è grande valuta un ripetitore mesh (es. Swisscom WLAN-Box) o un cavo.'
        } elseif ($pc.SegnalePct -lt 60) {
            Add-Finding 2 'Questo PC' "Segnale Wi-Fi debole ($($pc.SegnalePct)%, circa $($pc.SegnaleDbmStimato) dBm)" `
                'Segnale sufficiente per navigare ma la velocità reale è ridotta.' `
                'Riduci gli ostacoli tra PC e router o avvicina il router alla zona dove lo usi di più.'
        }
    }
    if ($pc.Banda -eq '2.4 GHz') {
        Add-Finding 2 'Questo PC' 'Il PC è connesso alla banda 2.4 GHz' `
            'La 2.4 GHz è più lenta e molto più disturbata (vicini, Bluetooth, microonde). La 5 GHz è in genere 3-5 volte più veloce a breve/media distanza.' `
            'Se sei vicino al router, collega il PC alla 5 GHz. Nella Internet-Box (Wi-Fi > impostazioni) puoi dare un nome diverso alla rete 5 GHz per sceglierla a mano.'
    }
    if ($pc.TipoRadio -and $pc.TipoRadio -match '802\.11[bga]$|802\.11n$') {
        Add-Finding 1 'Questo PC' "Scheda Wi-Fi del PC datata ($($pc.TipoRadio))" `
            'Lo standard usato dal PC limita la velocità massima indipendentemente dal router.' `
            'Una chiavetta/scheda Wi-Fi 6 (802.11ax) costa poco e può raddoppiare la velocità.'
    }
    if ($pc.RxMbps -ne $null -and $pc.RxMbps -lt 100) {
        Add-Finding 2 'Questo PC' "Velocità di collegamento bassa ($($pc.RxMbps) Mbps)" `
            'È la velocità massima teorica tra PC e router in questo momento; quella reale è circa la metà.' `
            'Di solito dipende da segnale debole, banda 2.4 GHz o canale affollato: vedi gli altri punti del report.'
    }
} else {
    Write-Host "   Questo PC non è connesso via Wi-Fi (forse via cavo): i test di rete misureranno il cavo." -ForegroundColor Yellow
    Add-Finding 0 'Questo PC' 'Il PC non è connesso in Wi-Fi' 'I test di latenza e velocità riflettono la connessione via cavo, non il Wi-Fi.' 'Per diagnosticare il Wi-Fi del PC, scollega il cavo e rilancia lo script.'
}
$Dati.PC = $pc

# ---------------------------------------------------------------- 2. Reti vicine
Step "Scansione delle reti Wi-Fi vicine"
$netLines = @(netsh wlan show networks mode=bssid 2>&1 | ForEach-Object { "$_" })
$vicine = New-Object System.Collections.ArrayList
$curSsid = ''; $cur = $null
foreach ($l in $netLines) {
    if ($l -match '^\s*SSID\s+\d+\s*:\s*(.*)$') { $curSsid = $Matches[1].Trim(); $cur = $null; continue }
    if ($l -match '^\s*BSSID\s+\d+\s*:\s*(.+)$') {
        $cur = [pscustomobject]@{ SSID = $curSsid; BSSID = $Matches[1].Trim(); Segnale = $null; Canale = $null; Banda = $null; UtilizzoPct = $null }
        [void]$vicine.Add($cur); continue
    }
    if ($cur) {
        if ($l -match "^\s*($reSignal)\s*:\s*(\d+)\s*%") { $cur.Segnale = [int]$Matches[2] }
        elseif ($l -match "^\s*($reChannel)\s*:\s*(\d+)") { $cur.Canale = [int]$Matches[2] }
        elseif ($l -match "^\s*($reBand)\s*:\s*(.+)$") { $cur.Banda = $Matches[2].Trim() }
        elseif ($l -match "^\s*($reUtil)\s*:.*\((\d+)\s*%\)") { $cur.UtilizzoPct = [int]$Matches[2] }
    }
}
foreach ($v in $vicine) { $v.Banda = Norm-Band $v.Banda $v.Canale }
$altre = @($vicine | Where-Object { $_.SSID -ne $pc.SSID })
Write-Host ("   Trovati {0} punti di accesso ({1} non tuoi)" -f $vicine.Count, $altre.Count)
if ($vicine.Count -eq 0) {
    Add-Finding 0 'Reti vicine' 'Impossibile leggere le reti vicine' `
        'Windows non ha restituito la lista delle reti. Su Windows 11 serve il permesso di posizione.' `
        'Impostazioni > Privacy e sicurezza > Posizione: attiva "Servizi di posizione" e "Consenti alle app desktop di accedere alla posizione", poi rilancia.'
}

# Punteggio di affollamento per i canali 2.4 GHz (1, 6, 11): più è alto, più il canale è disturbato
function Score24([int]$ch) {
    $s = 0
    foreach ($v in $altre) {
        if ($v.Banda -eq '2.4 GHz' -and $v.Canale -and [math]::Abs($v.Canale - $ch) -lt 5) { $s += [math]::Max($v.Segnale, 5) }
    }
    return $s
}
$score24 = [ordered]@{}; foreach ($c in 1, 6, 11) { $score24["$c"] = Score24 $c }
$best24 = ($score24.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
$Dati.RetiVicine = $vicine
$Dati.Punteggio24 = $score24

# ---------------------------------------------------------------- 3. Latenza
if (-not $Router) {
    try { $Router = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch {}
    if (-not $Router) { $Router = '192.168.1.1' }
}
Write-Host "   Router: $Router"

function Measure-Ping([string]$target, [int]$n) {
    $out = @(ping -n $n -w 1000 $target 2>&1 | ForEach-Object { "$_" })
    $t = @(); foreach ($l in $out) { if ($l -match '[=<]\s*(\d+)\s*ms\s+TTL') { $t += [int]$Matches[1] } }
    $r = [ordered]@{ Destinazione = $target; Inviati = $n; Ricevuti = $t.Count; PersiPct = [math]::Round(100 * ($n - $t.Count) / $n, 1); MediaMs = $null; MaxMs = $null; JitterMs = $null }
    if ($t.Count -gt 0) {
        $r.MediaMs = [math]::Round(($t | Measure-Object -Average).Average, 1)
        $r.MaxMs = ($t | Measure-Object -Maximum).Maximum
        if ($t.Count -gt 1) { $d = 0; for ($i = 1; $i -lt $t.Count; $i++) { $d += [math]::Abs($t[$i] - $t[$i - 1]) }; $r.JitterMs = [math]::Round($d / ($t.Count - 1), 1) }
    }
    return [pscustomobject]$r
}
Step "Test di latenza verso il router ($Ping ping, circa $Ping secondi)"
$pR = Measure-Ping $Router $Ping
Write-Host ("   Media {0} ms | Max {1} ms | Jitter {2} ms | Persi {3}%" -f $pR.MediaMs, $pR.MaxMs, $pR.JitterMs, $pR.PersiPct)
Step "Test di latenza verso Internet (8.8.8.8)"
$pI = Measure-Ping '8.8.8.8' $Ping
Write-Host ("   Media {0} ms | Max {1} ms | Jitter {2} ms | Persi {3}%" -f $pI.MediaMs, $pI.MaxMs, $pI.JitterMs, $pI.PersiPct)
$Dati.Ping = @($pR, $pI)

$tratto = if ($suWifi) { 'il Wi-Fi tra PC e router' } else { 'il collegamento tra PC e router' }
if ($pR.Ricevuti -eq 0) {
    Add-Finding 2 'Latenza' 'Il router non risponde al ping' "Non è stato possibile misurare $tratto." 'Verifica che l''indirizzo del router sia corretto (parametro -Router).'
} elseif ($pR.PersiPct -gt 5 -or $pR.MediaMs -gt 30) {
    Add-Finding 3 'Latenza' "Collegamento instabile verso il router (media $($pR.MediaMs) ms, persi $($pR.PersiPct)%)" `
        "Verso il router dovrebbero bastare 1-5 ms e 0% di persi. Il problema è $tratto, non la linea Swisscom." `
        'Tipico di segnale debole, canale affollato o interferenze: segui i consigli sul segnale e sul canale.'
} elseif ($pR.PersiPct -gt 1 -or $pR.MediaMs -gt 10 -or $pR.JitterMs -gt 10) {
    Add-Finding 2 'Latenza' "Collegamento verso il router non ottimale (media $($pR.MediaMs) ms, jitter $($pR.JitterMs) ms, persi $($pR.PersiPct)%)" `
        "Ci sono ritardi o picchi su $tratto. Si sentono soprattutto in videochiamate e giochi online." `
        'Controlla segnale, banda e affollamento del canale (vedi sotto).'
}
if ($pR.Ricevuti -gt 0 -and $pR.PersiPct -le 1 -and $pR.MediaMs -le 10) {
    if ($pI.Ricevuti -eq 0) {
        Add-Finding 3 'Linea Internet' 'Internet non risponde' 'Il router risponde ma Internet no.' 'Controlla lo stato della linea nella Internet-Box o chiama Swisscom.'
    } elseif ($pI.PersiPct -gt 2 -or $pI.MediaMs -gt 50 -or $pI.JitterMs -gt 20) {
        Add-Finding 2 'Linea Internet' "Latenza alta verso Internet (media $($pI.MediaMs) ms, persi $($pI.PersiPct)%) mentre il Wi-Fi è a posto" `
            'Il rallentamento è oltre il router: linea, rete Swisscom o qualcuno in casa che satura la banda.' `
            'Guarda la sezione "traffico in corso" dei dispositivi; se nessuno sta scaricando, fai uno speedtest via cavo e segnala a Swisscom.'
    }
}

# ---------------------------------------------------------------- 4. Speedtest
$speed = $null
if (-not $SenzaSpeedtest) {
    Step "Test di velocità in download (circa 10 secondi)"
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://speed.cloudflare.com/__down?bytes=200000000')
        $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
        $resp = $req.GetResponse(); $st = $resp.GetResponseStream()
        $buf = New-Object byte[] 262144; $tot = 0L; $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 10) { $n = $st.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $tot += $n }
        $sw.Stop(); $st.Close(); $resp.Close()
        if ($sw.Elapsed.TotalSeconds -gt 0) { $speed = [math]::Round(($tot * 8 / 1e6) / $sw.Elapsed.TotalSeconds, 1) }
        Write-Host "   Download: $speed Mbps"
    } catch { Write-Host "   Speedtest non riuscito: $($_.Exception.Message)" -ForegroundColor Yellow }
}
$Dati.DownloadMbps = $speed
if ($speed -ne $null -and $suWifi -and $pc.RxMbps) {
    if ($speed -lt 0.25 * $pc.RxMbps -and $pR.MediaMs -le 10 -and $speed -lt 100) {
        Add-Finding 1 'Velocità' "Download di $speed Mbps, molto sotto la velocità del Wi-Fi ($($pc.RxMbps) Mbps)" `
            'Il Wi-Fi potrebbe andare più veloce: il limite è altrove (abbonamento, linea o altri dispositivi che scaricano).' `
            'Confronta con la velocità del tuo abbonamento Swisscom e guarda chi sta usando banda nella tabella dei dispositivi.'
    }
}

# ---------------------------------------------------------------- 5. Internet-Box
Step "Connessione alla Internet-Box ($Router)"
$WsUrl = "http://$Router/ws"
$script:Ctx = $null; $script:Cookie = $null
function Invoke-Box([string]$Service, [string]$Method, $Params = @{}, [switch]$Auth) {
    $body = @{ service = $Service; method = $Method; parameters = $Params } | ConvertTo-Json -Depth 10 -Compress
    $h = @{ 'X-Requested-With' = 'XMLHttpRequest' }
    if ($Auth -and $script:Ctx) {
        $h['Authorization'] = "X-Sah $($script:Ctx)"; $h['X-Context'] = $script:Ctx
        if ($script:Cookie) { $h['Cookie'] = $script:Cookie }
    }
    try {
        $r = Invoke-WebRequest -Uri $WsUrl -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
            -ContentType 'application/x-sah-ws-4-call+json' -Headers $h -UseBasicParsing -TimeoutSec 15
        return ($r.Content | ConvertFrom-Json)
    } catch { return $null }
}

$box = Invoke-Box 'DeviceInfo' 'get'
$boxInfo = P $box 'status'
if (-not $boxInfo) {
    Write-Host "   La Internet-Box non risponde su $WsUrl" -ForegroundColor Yellow
    Add-Finding 0 'Router' 'Impossibile leggere i dati della Internet-Box' "Nessuna risposta da $WsUrl." 'Verifica di essere connesso alla rete di casa e che il router sia una Internet-Box Swisscom; puoi indicare l''indirizzo con -Router.'
} else {
    $upGiorni = [math]::Round((ToNum (P $boxInfo 'UpTime')) / 86400, 1)
    Write-Host ("   {0} {1} - firmware {2} - acceso da {3} giorni" -f (P $boxInfo 'Manufacturer'), (P $boxInfo 'ModelName'), (P $boxInfo 'SoftwareVersion'), $upGiorni)
    $Dati.Router = [ordered]@{ Modello = P $boxInfo 'ModelName'; Firmware = P $boxInfo 'SoftwareVersion'; AccesoGiorni = $upGiorni }
    if ($upGiorni -gt 60) {
        Add-Finding 1 'Router' "Il router è acceso da $upGiorni giorni senza riavvio" `
            'Dopo molte settimane alcuni router accumulano rallentamenti (memoria, tabelle piene).' `
            'Un riavvio della Internet-Box (dall''interfaccia o staccando la corrente 30 secondi) è un test gratuito.'
    }

    $wan = P (Invoke-Box 'NMC' 'getWANStatus') 'data'
    if ($wan) {
        $Dati.Router.Linea = [ordered]@{ Tipo = P $wan 'LinkType'; Stato = P $wan 'LinkState'; Connessione = P $wan 'ConnectionState' }
        if ((P $wan 'LinkState') -ne 'up') {
            Add-Finding 3 'Linea Internet' "Linea Internet non attiva (stato: $(P $wan 'LinkState'))" 'Il router segnala la linea giù.' 'Controlla i cavi della linea e lo stato su swisscom.ch o chiama il supporto.'
        }
    }

    # Login
    $sec = Read-Host "   Password dell'interfaccia della Internet-Box (utente '$Utente'). Invio per saltare" -AsSecureString
    $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ($pw) {
        try {
            $lb = @{ service = 'sah.Device.Information'; method = 'createContext'; parameters = @{ applicationName = 'webui'; username = $Utente; password = $pw } } | ConvertTo-Json -Compress
            $lr = Invoke-WebRequest -Uri $WsUrl -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($lb)) -ContentType 'application/x-sah-ws-4-call+json' `
                -Headers @{ Authorization = 'X-Sah-Login' } -UseBasicParsing -TimeoutSec 15
            $lj = $lr.Content | ConvertFrom-Json
            $script:Ctx = P (P $lj 'data') 'contextID'
            $sc = (@($lr.Headers['Set-Cookie']) -join ', ')
            if ($script:Ctx -and $sc -match '([^=;/\s,]+)/sessid=([^;,\s]+)') {
                $script:Cookie = "$($Matches[1])/context=$($script:Ctx); swc/deviceID=$($Matches[1]); $($Matches[1])/sessid=$($Matches[2])"
            }
        } catch {}
        $pw = $null
        if ($script:Ctx) { Write-Host "   Accesso riuscito." -ForegroundColor Green }
        else {
            Write-Host "   Accesso non riuscito (password errata?). Continuo con i dati pubblici." -ForegroundColor Yellow
            Add-Finding 0 'Router' 'Accesso alla Internet-Box non riuscito' 'Senza accesso non si vedono dispositivi connessi e canali.' 'Rilancia lo script con la password dell''interfaccia web (stessa che usi su http://internetbox.home).'
        }
    }

    $wifi = P (Invoke-Box 'NMC.Wifi' 'get' @{} -Auth) 'data'
    if ($wifi) {
        $Dati.Router.Wifi = [ordered]@{ Attivo = P $wifi 'Enable'; Programmazione = P $wifi 'Scheduler'; WPS = P $wifi 'WPSEnable' }
        if ((P $wifi 'Scheduler') -eq $true) {
            Add-Finding 1 'Router' 'È attiva una programmazione oraria del Wi-Fi' 'Il Wi-Fi si spegne o si limita in certi orari.' 'Se il Wi-Fi "sparisce" sempre alla stessa ora, controlla la programmazione nella Internet-Box.'
        }
    }

    if ($script:Ctx) {
        # Reti Wi-Fi (access point)
        $aps = @()
        $apr = Invoke-Box 'Devices' 'get' @{ expression = 'lan and vap' } -Auth
        foreach ($a in @(P $apr 'status')) {
            if ($null -eq $a) { continue }
            $aps += [pscustomobject]@{
                Chiave = P $a 'Key'; SSID = P $a 'SSID'; Attiva = P $a 'Enabled'
                Banda = Norm-Band (P $a 'OperatingFrequencyBand') (P $a 'Channel')
                Canale = ToNum (P $a 'Channel'); Standard = P $a 'OperatingStandards'
                Ospiti = ("$(P $a 'Key')" -match 'guest')
            }
        }
        $Dati.Router.Reti = $aps

        # Radio e client associati (dati dettagliati, dipendono dal firmware)
        $mib = Invoke-Box 'NeMo.Intf.lan' 'getMIBs' @{ mibs = 'wlanradio wlanvap' } -Auth
        $Dati.Router.MIB = $mib
        $radios = @()
        foreach ($f in (Find-Objects $mib { param($o) ($o.PSObject.Properties['Channel']) -and ($o.PSObject.Properties['OperatingFrequencyBand']) })) {
            if ($f.Path -notmatch 'wlanradio') { continue }
            $o = $f.Obj
            $bw = P $o 'CurrentOperatingChannelBandwidth'; if (-not $bw) { $bw = P $o 'OperatingChannelBandwidth' }
            $radios += [pscustomobject]@{
                Banda = Norm-Band (P $o 'OperatingFrequencyBand') (P $o 'Channel'); Canale = ToNum (P $o 'Channel')
                Larghezza = "$bw"; CanaleAuto = P $o 'AutoChannelEnable'; Standard = P $o 'OperatingStandards'
            }
        }
        $Dati.Router.Radio = $radios

        function Get-Assoc($m) {
            $res = @()
            foreach ($f in (Find-Objects $m { param($o) ($o.PSObject.Properties['MACAddress']) -and (($o.PSObject.Properties['SignalStrength']) -or ($o.PSObject.Properties['LastDataDownlinkRate'])) })) {
                $vap = if ($f.Path -match 'wlanvap/([^/\[]+)') { $Matches[1] } else { '' }
                $o = $f.Obj
                $bytes = $null
                $tx = ToNum (P $o 'TxBytes'); $rx = ToNum (P $o 'RxBytes')
                if ($tx -ne $null -or $rx -ne $null) { $bytes = [double]$tx + [double]$rx }
                $res += [pscustomobject]@{
                    MAC = NormMac (P $o 'MACAddress'); Vap = $vap; Attivo = P $o 'Active'
                    Segnale = ToNum (P $o 'SignalStrength'); SNR = ToNum (P $o 'SignalNoiseRatio')
                    Down = ToNum (P $o 'LastDataDownlinkRate'); Up = ToNum (P $o 'LastDataUplinkRate')
                    Standard = P $o 'OperatingStandard'; Bytes = $bytes
                }
            }
            return $res
        }
        $assoc = @(Get-Assoc $mib)

        # Traffico in corso: secondo campione dopo 10 secondi
        $traffico = @{}
        if (@($assoc | Where-Object { $_.Bytes -ne $null }).Count -gt 0) {
            Step "Misuro chi sta usando banda adesso (10 secondi)"
            $t0 = Get-Date; Start-Sleep -Seconds 10
            $assoc2 = @(Get-Assoc (Invoke-Box 'NeMo.Intf.lan' 'getMIBs' @{ mibs = 'wlanvap' } -Auth))
            $secs = ((Get-Date) - $t0).TotalSeconds
            foreach ($a in $assoc) {
                $b = $assoc2 | Where-Object { $_.MAC -eq $a.MAC } | Select-Object -First 1
                if ($b -and $a.Bytes -ne $null -and $b.Bytes -ne $null -and $b.Bytes -ge $a.Bytes) {
                    $traffico[$a.MAC] = [math]::Round(($b.Bytes - $a.Bytes) * 8 / 1e6 / $secs, 2)
                }
            }
        }
        # Velocità di collegamento: alcuni firmware danno kbps, altri Mbps
        $maxRate = ($assoc | ForEach-Object { $_.Down } | Where-Object { $_ } | Measure-Object -Maximum).Maximum
        $rateDiv = if ($maxRate -gt 10000) { 1000 } else { 1 }

        # Dispositivi
        $apBand = @{}; foreach ($a in $aps) { if ($a.Chiave) { $apBand["$($a.Chiave)"] = $a.Banda } }
        $devr = Invoke-Box 'Devices' 'get' @{ expression = 'lan and not self' } -Auth
        $clienti = @(); $visti = @{}
        foreach ($d in @(P $devr 'status')) {
            if ($null -eq $d) { continue }
            $mac = NormMac (P $d 'PhysAddress')
            $as = $assoc | Where-Object { $_.MAC -eq $mac } | Select-Object -First 1
            $l2 = "$(P $d 'Layer2Interface')"
            $isWifi = ($apBand.ContainsKey($l2)) -or ($l2 -match '^wl|wifi|vap') -or ($as) -or ((P $d 'SignalStrength') -ne $null)
            $sig = if ($as -and $as.Segnale -ne $null) { $as.Segnale } else { ToNum (P $d 'SignalStrength') }
            if ($sig -ne $null -and $sig -gt 0) { $sig = -$sig }
            $banda = if ($apBand.ContainsKey($l2)) { $apBand[$l2] } elseif ($as -and $apBand.ContainsKey($as.Vap)) { $apBand[$as.Vap] } elseif ($isWifi) { '?' } else { 'Cavo' }
            $clienti += [pscustomobject]@{
                Nome = "$(P $d 'Name')"; IP = "$(P $d 'IPAddress')"; MAC = $mac; Produttore = "$(P $d 'MACVendor')"
                Attivo = [bool](P $d 'Active'); WiFi = [bool]$isWifi; Banda = $banda
                SegnaleDbm = $sig; SNR = if ($as -and $as.SNR -ne $null) { $as.SNR } else { ToNum (P $d 'SignalNoiseRatio') }
                LinkMbps = if ($as -and $as.Down) { [math]::Round($as.Down / $rateDiv, 0) } else { $null }
                Standard = if ($as) { $as.Standard } else { $null }
                TrafficoMbps = if ($traffico.ContainsKey($mac)) { $traffico[$mac] } else { $null }
            }
            $visti[$mac] = $true
        }
        foreach ($a in $assoc) {
            if ($visti.ContainsKey($a.MAC)) { continue }
            $sig = $a.Segnale; if ($sig -ne $null -and $sig -gt 0) { $sig = -$sig }
            $clienti += [pscustomobject]@{
                Nome = $a.MAC; IP = ''; MAC = $a.MAC; Produttore = ''; Attivo = $true; WiFi = $true
                Banda = if ($apBand.ContainsKey($a.Vap)) { $apBand[$a.Vap] } else { '?' }
                SegnaleDbm = $sig; SNR = $a.SNR; LinkMbps = if ($a.Down) { [math]::Round($a.Down / $rateDiv, 0) } else { $null }
                Standard = $a.Standard; TrafficoMbps = if ($traffico.ContainsKey($a.MAC)) { $traffico[$a.MAC] } else { $null }
            }
        }
        $Dati.Router.Dispositivi = $clienti
        $attivi = @($clienti | Where-Object { $_.Attivo })
        $wifiAttivi = @($attivi | Where-Object { $_.WiFi })
        Write-Host ("   Dispositivi attivi: {0} (di cui {1} in Wi-Fi)" -f $attivi.Count, $wifiAttivi.Count)

        # --- Analisi router
        $reti24 = @($aps | Where-Object { $_.Banda -eq '2.4 GHz' -and -not $_.Ospiti })
        $reti5 = @($aps | Where-Object { $_.Banda -eq '5 GHz' -and -not $_.Ospiti })
        if ($reti5.Count -gt 0 -and @($reti5 | Where-Object { $_.Attiva }).Count -eq 0) {
            Add-Finding 3 'Router' 'La rete Wi-Fi a 5 GHz è spenta' 'Tutti i dispositivi sono costretti sulla 2.4 GHz, più lenta e disturbata.' 'Attiva la 5 GHz nelle impostazioni Wi-Fi della Internet-Box.'
        }
        foreach ($a in $reti24) {
            if ($a.Standard -and "$($a.Standard)" -match '(^|,)\s*b\s*(,|$)') {
                Add-Finding 2 'Router' "Modalità di compatibilità 802.11b attiva sulla 2.4 GHz ($($a.Standard))" `
                    'Un solo dispositivo molto vecchio in 802.11b rallenta tutta la rete 2.4 GHz.' `
                    'Se non hai dispositivi di oltre 15 anni fa, imposta la modalità g/n/ax (o n/ax) nelle impostazioni avanzate Wi-Fi.'
                break
            }
        }
        $ospiti = @($aps | Where-Object { $_.Ospiti -and $_.Attiva })
        if ($ospiti.Count -gt 0) {
            Add-Finding 1 'Router' 'La rete ospiti è attiva' 'Ogni rete in più occupa un po'' di tempo radio con i suoi segnali, anche se nessuno la usa.' 'Spegnila quando non hai ospiti.'
        }
        # Canale 2.4 GHz del router rispetto ai vicini
        $ch24 = ($reti24 | Where-Object { $_.Attiva -and $_.Canale } | Select-Object -First 1).Canale
        if (-not $ch24 -and $pc.Banda -eq '2.4 GHz') { $ch24 = $pc.Canale }
        if ($ch24 -and $altre.Count -gt 0) {
            $cur24 = Score24 ([int]$ch24); $bestScore = $score24[$best24]
            if ($ch24 -notin 1, 6, 11) {
                Add-Finding 2 'Canali' "Il router usa il canale 2.4 GHz $ch24 (non è 1, 6 o 11)" `
                    'I canali intermedi si sovrappongono a due gruppi di vicini contemporaneamente.' `
                    "Imposta manualmente il canale $best24, il meno affollato in questo momento."
            } elseif ($cur24 -gt 100 -and $cur24 -gt 1.5 * $bestScore -and "$ch24" -ne $best24) {
                Add-Finding 2 'Canali' "Canale 2.4 GHz $ch24 affollato dalle reti vicine" `
                    "Punteggio affollamento: canale $ch24 = $cur24, canale $best24 = $bestScore (più basso è meglio)." `
                    "Nella Internet-Box imposta il canale 2.4 GHz su $best24. Ripeti il test in orari diversi (la sera i vicini usano di più la rete)."
            }
        }
        # Canale 5 GHz
        $ch5 = ($reti5 | Where-Object { $_.Attiva -and $_.Canale } | Select-Object -First 1).Canale
        if ($ch5) {
            $sovr5 = @($altre | Where-Object { $_.Banda -eq '5 GHz' -and $_.Canale -and [math]::Abs($_.Canale - $ch5) -lt 8 -and $_.Segnale -ge 30 })
            if ($sovr5.Count -ge 3) {
                Add-Finding 2 'Canali' "Canale 5 GHz $ch5 condiviso con $($sovr5.Count) reti vicine forti" `
                    'Sullo stesso blocco di canali le reti si dividono il tempo di trasmissione.' `
                    'Prova un altro gruppo di canali a 5 GHz (36-48 oppure 100-128) nelle impostazioni Wi-Fi.'
            }
        }
        foreach ($r in $radios) {
            if ($r.Banda -eq '5 GHz' -and $r.Larghezza -match '^\s*20') {
                Add-Finding 2 'Canali' 'La rete 5 GHz usa canali larghi solo 20 MHz' 'Con 20 MHz la velocità massima è circa un quarto rispetto a 80 MHz.' 'Imposta la larghezza di banda 5 GHz su 80 MHz (o "Auto").'
            }
            if ($r.Banda -eq '2.4 GHz' -and $r.Larghezza -match '^\s*40' -and $altre.Count -gt 5) {
                Add-Finding 1 'Canali' 'La rete 2.4 GHz usa canali da 40 MHz in una zona affollata' 'In 2.4 GHz i 40 MHz si sovrappongono quasi a tutti i vicini e aumentano le interferenze.' 'Imposta la larghezza 2.4 GHz a 20 MHz: spesso diventa più stabile.'
            }
        }
        # Dispositivi
        if ($wifiAttivi.Count -gt 25) {
            Add-Finding 2 'Dispositivi' "Molti dispositivi Wi-Fi attivi ($($wifiAttivi.Count))" 'Il tempo radio è condiviso: più dispositivi parlano, meno ne resta per ciascuno.' 'Collega via cavo quello che puoi (TV, console, PC fisso) e scollega i dispositivi inutilizzati.'
        }
        $deboli = @($wifiAttivi | Where-Object { $_.SegnaleDbm -ne $null -and $_.SegnaleDbm -lt -75 })
        if ($deboli.Count -gt 0) {
            $nomi = ($deboli | ForEach-Object { "$(if ($_.Nome) { $_.Nome } else { $_.MAC }) ($($_.SegnaleDbm) dBm)" }) -join ', '
            Add-Finding 2 'Dispositivi' "$($deboli.Count) dispositivi con segnale debole" `
                "Un dispositivo lontano trasmette lentamente e occupa la radio più a lungo, rallentando anche gli altri. Dispositivi: $nomi" `
                'Avvicinali al router, collegali via cavo o aggiungi un punto di accesso mesh nella zona dove si trovano.'
        }
        $lenti = @($wifiAttivi | Where-Object { $_.LinkMbps -ne $null -and $_.LinkMbps -gt 0 -and $_.LinkMbps -lt 20 })
        if ($lenti.Count -gt 0) {
            $nomi = ($lenti | ForEach-Object { "$(if ($_.Nome) { $_.Nome } else { $_.MAC }) ($($_.LinkMbps) Mbps)" }) -join ', '
            Add-Finding 1 'Dispositivi' "$($lenti.Count) dispositivi collegati a velocità molto bassa" "Dispositivi: $nomi" 'Spesso sono dispositivi lontani o vecchi (prese smart, telecamere): se possibile spostali sulla 2.4 GHz vicino al router o sostituiscili.'
        }
        $su24 = @($wifiAttivi | Where-Object { $_.Banda -eq '2.4 GHz' })
        if ($reti5.Count -gt 0 -and $wifiAttivi.Count -ge 4 -and $su24.Count -gt 0.7 * $wifiAttivi.Count) {
            Add-Finding 1 'Dispositivi' "$($su24.Count) dispositivi su $($wifiAttivi.Count) sono sulla 2.4 GHz" 'La banda 2.4 GHz è la più lenta e disturbata.' 'Telefoni, PC e TV recenti dovrebbero stare sulla 5 GHz: separa i nomi delle due reti e collegali alla 5 GHz.'
        }
        $pesanti = @($clienti | Where-Object { $_.TrafficoMbps -ne $null -and $_.TrafficoMbps -ge 5 } | Sort-Object TrafficoMbps -Descending)
        if ($pesanti.Count -gt 0) {
            $nomi = ($pesanti | ForEach-Object { "$(if ($_.Nome) { $_.Nome } else { $_.MAC }) ($($_.TrafficoMbps) Mbps)" }) -join ', '
            Add-Finding 2 'Traffico' 'Dispositivi che stanno usando molta banda in questo momento' `
                "Durante il test: $nomi. Download, aggiornamenti, streaming 4K o backup nel cloud rallentano tutti gli altri." `
                'Se non è voluto, controlla quel dispositivo (aggiornamenti automatici, backup, torrent).'
        }
    }
}

# ---------------------------------------------------------------- 6. Report
Step "Creazione del report"
$ordinati = @($script:Findings | Sort-Object @{ Expression = 'Livello'; Descending = $true }, @{ Expression = 'Ordine'; Descending = $false })
$problemi = @($ordinati | Where-Object { $_.Livello -ge 1 })
function H($s) { return [System.Net.WebUtility]::HtmlEncode("$s") }
$lab = @{ 3 = 'ALTO'; 2 = 'MEDIO'; 1 = 'BASSO'; 0 = 'INFO' }
$col = @{ 3 = '#d32f2f'; 2 = '#f57c00'; 1 = '#c9a800'; 0 = '#607d8b' }

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append(@"
<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Diagnosi Wi-Fi $Stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px;color:#222;background:#fafafa}
h1{margin-bottom:4px}h2{margin-top:32px;border-bottom:2px solid #ddd;padding-bottom:4px}
.top{background:#fff;border-left:6px solid #1976d2;padding:16px 20px;box-shadow:0 1px 3px #0002;border-radius:4px}
.f{background:#fff;padding:12px 16px;margin:10px 0;border-radius:4px;box-shadow:0 1px 2px #0002;border-left:6px solid #999}
.tag{display:inline-block;color:#fff;font-size:12px;font-weight:bold;padding:2px 8px;border-radius:10px;margin-right:8px}
.area{color:#777;font-size:13px}.c{margin-top:6px}.c b{color:#1976d2}
table{border-collapse:collapse;width:100%;background:#fff;font-size:14px}th,td{border:1px solid #ddd;padding:5px 8px;text-align:left}th{background:#eee}
.muted{color:#888;font-size:13px}
</style></head><body>
<h1>Diagnosi Wi-Fi</h1><div class="muted">$(H (Get-Date -Format 'dd.MM.yyyy HH:mm')) - Router $(H $Router)</div>
"@)

[void]$sb.Append('<h2>Consiglio principale</h2><div class="top">')
if ($problemi.Count -gt 0) {
    $t = $problemi[0]
    [void]$sb.Append("<div><span class='tag' style='background:$($col[$t.Livello])'>$($lab[$t.Livello])</span><b>$(H $t.Titolo)</b></div><div class='c'><b>Cosa fare:</b> $(H $t.Consiglio)</div><div class='muted' style='margin-top:6px'>Perché: $(H $t.Dettaglio)</div>")
} else {
    [void]$sb.Append('<b>Nessun problema evidente trovato.</b> Se il Wi-Fi è lento solo in certi momenti, rilancia lo script proprio quando succede.')
}
[void]$sb.Append('</div>')

[void]$sb.Append("<h2>Tutti i punti trovati ($($problemi.Count) problemi)</h2>")
foreach ($f in $ordinati) {
    [void]$sb.Append("<div class='f' style='border-left-color:$($col[$f.Livello])'><span class='tag' style='background:$($col[$f.Livello])'>$($lab[$f.Livello])</span><span class='area'>$(H $f.Area)</span><div style='margin-top:4px'><b>$(H $f.Titolo)</b></div><div>$(H $f.Dettaglio)</div><div class='c'><b>Cosa fare:</b> $(H $f.Consiglio)</div></div>")
}

[void]$sb.Append('<h2>Questo PC</h2><table>')
foreach ($k in $pc.Keys) { [void]$sb.Append("<tr><th>$(H $k)</th><td>$(H $pc[$k])</td></tr>") }
[void]$sb.Append('</table>')

[void]$sb.Append('<h2>Latenza e velocità</h2><table><tr><th>Destinazione</th><th>Media ms</th><th>Max ms</th><th>Jitter ms</th><th>Persi %</th></tr>')
foreach ($p in @($pR, $pI)) { [void]$sb.Append("<tr><td>$(H $p.Destinazione)</td><td>$(H $p.MediaMs)</td><td>$(H $p.MaxMs)</td><td>$(H $p.JitterMs)</td><td>$(H $p.PersiPct)</td></tr>") }
[void]$sb.Append("</table><p>Download: <b>$(if ($speed -ne $null) { "$speed Mbps" } else { 'non misurato' })</b></p>")

if ($Dati.Contains('Router')) {
    [void]$sb.Append("<h2>Internet-Box</h2><p>$(H $Dati.Router.Modello) - firmware $(H $Dati.Router.Firmware) - acceso da $(H $Dati.Router.AccesoGiorni) giorni</p>")
    if ($Dati.Router.Contains('Reti') -and $Dati.Router.Reti) {
        [void]$sb.Append('<table><tr><th>Rete</th><th>Banda</th><th>Canale</th><th>Standard</th><th>Attiva</th></tr>')
        foreach ($a in $Dati.Router.Reti) { [void]$sb.Append("<tr><td>$(H $a.SSID)$(if ($a.Ospiti) { ' (ospiti)' })</td><td>$(H $a.Banda)</td><td>$(H $a.Canale)</td><td>$(H $a.Standard)</td><td>$(H $a.Attiva)</td></tr>") }
        [void]$sb.Append('</table>')
    }
    if ($Dati.Router.Contains('Dispositivi') -and $Dati.Router.Dispositivi) {
        [void]$sb.Append('<h2>Dispositivi attivi</h2><table><tr><th>Nome</th><th>IP</th><th>Collegamento</th><th>Segnale dBm</th><th>Link Mbps</th><th>Traffico ora Mbps</th><th>Produttore</th></tr>')
        foreach ($c in @($Dati.Router.Dispositivi | Where-Object { $_.Attivo } | Sort-Object @{ Expression = { if ($_.TrafficoMbps) { $_.TrafficoMbps } else { 0 } }; Descending = $true }, Nome)) {
            $sigStyle = if ($c.SegnaleDbm -ne $null -and $c.SegnaleDbm -lt -75) { " style='color:#d32f2f;font-weight:bold'" } else { '' }
            [void]$sb.Append("<tr><td>$(H $c.Nome)</td><td>$(H $c.IP)</td><td>$(H $c.Banda)</td><td$sigStyle>$(H $c.SegnaleDbm)</td><td>$(H $c.LinkMbps)</td><td>$(H $c.TrafficoMbps)</td><td>$(H $c.Produttore)</td></tr>")
        }
        [void]$sb.Append('</table><p class="muted">Segnale: oltre -60 dBm ottimo, -60/-70 buono, -70/-75 scarso, sotto -75 debole.</p>')
    }
}

[void]$sb.Append('<h2>Reti vicine</h2>')
if ($vicine.Count -gt 0) {
    [void]$sb.Append("<p>Affollamento 2.4 GHz (più basso è meglio): canale 1 = $($score24['1']), canale 6 = $($score24['6']), canale 11 = $($score24['11']). Migliore ora: <b>$best24</b>.</p>")
    [void]$sb.Append('<table><tr><th>Nome rete</th><th>Banda</th><th>Canale</th><th>Segnale %</th><th>Utilizzo canale %</th></tr>')
    foreach ($v in @($vicine | Sort-Object Banda, Canale, @{ Expression = 'Segnale'; Descending = $true })) {
        $mine = if ($v.SSID -eq $pc.SSID) { ' <b>(tua)</b>' } else { '' }
        [void]$sb.Append("<tr><td>$(H $v.SSID)$mine</td><td>$(H $v.Banda)</td><td>$(H $v.Canale)</td><td>$(H $v.Segnale)</td><td>$(H $v.UtilizzoPct)</td></tr>")
    }
    [void]$sb.Append('</table>')
} else { [void]$sb.Append('<p>Non disponibili.</p>') }
[void]$sb.Append('<p class="muted">Report creato da wifi-diagnosi.ps1 - nessuna impostazione del router è stata modificata.</p></body></html>')

$htmlPath = Join-Path $Cartella "Report-WiFi-$Stamp.html"
$jsonPath = Join-Path $Cartella "Dati-WiFi-$Stamp.json"
[IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
try { [IO.File]::WriteAllText($jsonPath, ($Dati | ConvertTo-Json -Depth 25), (New-Object System.Text.UTF8Encoding $false)) } catch {}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
if ($problemi.Count -gt 0) {
    Write-Host "Problemi trovati: $($problemi.Count)" -ForegroundColor Yellow
    foreach ($f in $problemi) { Write-Host ("  [{0}] {1}" -f $lab[$f.Livello], $f.Titolo) -ForegroundColor $(if ($f.Livello -ge 3) { 'Red' } elseif ($f.Livello -eq 2) { 'Yellow' } else { 'Gray' }) }
} else { Write-Host "Nessun problema evidente trovato." -ForegroundColor Green }
Write-Host ""
Write-Host "Report: $htmlPath"
Write-Host "Dati tecnici: $jsonPath"
try { Start-Process $htmlPath } catch {}
