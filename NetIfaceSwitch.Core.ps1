# NetIfaceSwitch.Core.ps1
# Logique du Gestionnaire de Priorité Réseau, séparée de l'interface graphique
# pour pouvoir être testée (Pester) et réutilisée par RESET_RESEAU.ps1.
#
# A charger par dot-source :  . (Join-Path $PSScriptRoot 'NetIfaceSwitch.Core.ps1')
# Compatible Windows PowerShell 5.1 (pas de syntaxe propre à PowerShell 7).
#
# Vocabulaire :
#   State   : état lu sur le système pour une interface (métriques, routes, IPv6...)
#   Entry   : une ligne de l'ordre choisi par l'utilisateur (vue Simple), présente ou absente
#   Desired : réglages voulus pour une interface ($null sur un champ = ne pas y toucher)
#   Action  : une modification élémentaire (avec sa valeur d'origine pour pouvoir l'annuler)

$script:NisMinInterfaceMetric = 1
$script:NisMaxMetric = 9999
$script:NisDefaultRoutePrefix = '0.0.0.0/0'
$script:NisLegacyAliasPattern = 'Wi-Fi|WiFi|Ethernet'

# ---------------------------------------------------------------------------
# Classification des interfaces (fonctions pures)
# ---------------------------------------------------------------------------

function Get-NisInterfaceKind {
    <# Renvoie 'Wi-Fi', 'Ethernet' ou 'Autre'. #>
    [CmdletBinding()]
    param(
        [string]$Alias,
        [string]$Description,
        [string]$PhysicalMediaType
    )
    if ($PhysicalMediaType -match '802\.11|Wireless' -or $Alias -match 'Wi-?Fi|WLAN|Wireless|Sans fil' -or $Description -match 'Wi-?Fi|Wireless|WLAN|802\.11') {
        return 'Wi-Fi'
    }
    if ($PhysicalMediaType -match '802\.3' -or $Alias -match 'Ethernet' -or $Description -match 'Ethernet|GbE|Gigabit') {
        return 'Ethernet'
    }
    return 'Autre'
}

function Get-NisEntryKey {
    <# Clé stable d'une interface : GUID de la carte si connu, sinon son nom. #>
    [CmdletBinding()]
    param([string]$Guid, [string]$Alias)
    if ($Guid) { return "guid:$($Guid.ToLowerInvariant())" }
    return "alias:$Alias"
}

function ConvertTo-NisInterfaceState {
    <# Assemble l'état d'une interface à partir des objets renvoyés par les cmdlets NetTCPIP / NetAdapter. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $IPInterface,
        $Adapter,
        [object[]]$Routes = @(),
        [object[]]$Addresses = @(),
        $IPv6Interface,
        $IPv6Binding
    )
    $alias = [string]$IPInterface.InterfaceAlias
    $guid = $null
    $description = $null
    $media = $null
    $isPhysical = $false
    $status = $null
    if ($Adapter) {
        $guid = [string]$Adapter.InterfaceGuid
        $description = [string]$Adapter.InterfaceDescription
        $media = [string]$Adapter.PhysicalMediaType
        $isPhysical = [bool]$Adapter.HardwareInterface -and -not [bool]$Adapter.Virtual
        $status = [string]$Adapter.Status
    }
    if (-not $status) {
        if ([string]$IPInterface.ConnectionState -eq 'Connected') { $status = 'Up' } else { $status = 'Disconnected' }
    }

    # Une route par passerelle (Get-NetRoute peut renvoyer la même route depuis plusieurs magasins)
    $routeList = @()
    $seen = @{}
    foreach ($r in @($Routes | Where-Object { $null -ne $_ })) {
        $nh = [string]$r.NextHop
        if ($seen.ContainsKey($nh)) { continue }
        $seen[$nh] = $true
        $routeList += [pscustomobject]@{ NextHop = $nh; RouteMetric = [int]$r.RouteMetric }
    }
    $routeMetric = $null
    if ($routeList.Count -gt 0) {
        $routeMetric = ($routeList | Measure-Object -Property RouteMetric -Minimum).Minimum
        $routeMetric = [int]$routeMetric
    }
    $interfaceMetric = [int]$IPInterface.InterfaceMetric
    $effective = $null
    if ($null -ne $routeMetric) { $effective = $interfaceMetric + $routeMetric }

    $ipv4 = @($Addresses | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.IPAddress } | Where-Object { $_ -and $_ -notlike '169.254.*' })
    if ($ipv4.Count -eq 0) {
        $ipv4 = @($Addresses | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.IPAddress } | Where-Object { $_ })
    }

    $ipv6Enabled = $null
    if ($null -ne $IPv6Binding) { $ipv6Enabled = [bool]$IPv6Binding.Enabled }
    $hasIPv6If = $null -ne $IPv6Interface
    $ipv6Auto = $null
    $ipv6Metric = $null
    if ($hasIPv6If) {
        $ipv6Auto = ([string]$IPv6Interface.AutomaticMetric -eq 'Enabled')
        $ipv6Metric = [int]$IPv6Interface.InterfaceMetric
    }

    $isLoopback = $alias -like 'Loopback*'
    $isUsable = (-not $isLoopback) -and ($isPhysical -or ((-not $Adapter) -and $alias -match $script:NisLegacyAliasPattern))

    [pscustomobject]@{
        Key                 = (Get-NisEntryKey -Guid $guid -Alias $alias)
        InterfaceIndex      = [int]$IPInterface.InterfaceIndex
        Alias               = $alias
        Guid                = $guid
        Description         = $description
        Kind                = (Get-NisInterfaceKind -Alias $alias -Description $description -PhysicalMediaType $media)
        Status              = $status
        IsUp                = ($status -eq 'Up')
        IsPhysical          = $isPhysical
        IsLoopback          = $isLoopback
        IsUsable            = $isUsable
        IPv4Address         = ($ipv4 -join ', ')
        AutomaticMetric     = ([string]$IPInterface.AutomaticMetric -eq 'Enabled')
        InterfaceMetric     = $interfaceMetric
        Routes              = $routeList
        RouteMetric         = $routeMetric
        EffectiveMetric     = $effective
        IPv6Enabled         = $ipv6Enabled
        HasIPv6Interface    = $hasIPv6If
        IPv6AutomaticMetric = $ipv6Auto
        IPv6InterfaceMetric = $ipv6Metric
    }
}

# ---------------------------------------------------------------------------
# Lecture de l'état du système (lecture seule)
# ---------------------------------------------------------------------------

function Get-NisInterfaceStates {
    <#
      Lit l'état de toutes les interfaces IPv4 (hors loopback).
      Sans -IncludeVirtual, ne garde que les cartes physiques / utilisables.
    #>
    [CmdletBinding()]
    param([switch]$IncludeVirtual)

    $ipv4 = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)
    $ipv6 = @(Get-NetIPInterface -AddressFamily IPv6 -ErrorAction SilentlyContinue)
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -DestinationPrefix $script:NisDefaultRoutePrefix -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $bindings = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue)

    foreach ($if in $ipv4) {
        $idx = [int]$if.InterfaceIndex
        $alias = [string]$if.InterfaceAlias
        $adapter = $adapters | Where-Object { [int]$_.ifIndex -eq $idx } | Select-Object -First 1
        $state = ConvertTo-NisInterfaceState -IPInterface $if -Adapter $adapter `
            -Routes @($routes | Where-Object { [int]$_.InterfaceIndex -eq $idx }) `
            -Addresses @($addresses | Where-Object { [int]$_.InterfaceIndex -eq $idx }) `
            -IPv6Interface ($ipv6 | Where-Object { [int]$_.InterfaceIndex -eq $idx } | Select-Object -First 1) `
            -IPv6Binding ($bindings | Where-Object { [string]$_.Name -eq $alias } | Select-Object -First 1)
        if ($state.IsLoopback) { continue }
        if (-not $IncludeVirtual -and -not $state.IsUsable) { continue }
        $state
    }
}

function Find-NisEffectiveRoute {
    <#
      Indique quelle interface Windows choisit pour joindre une adresse Internet
      (Find-NetRoute : calcul local, aucun paquet envoyé).
    #>
    [CmdletBinding()]
    param([string]$RemoteAddress = '8.8.8.8')
    $res = @(Find-NetRoute -RemoteIPAddress $RemoteAddress -ErrorAction Stop)
    $route = $res | Where-Object { $null -ne $_.PSObject.Properties['NextHop'] } | Select-Object -First 1
    $addr = $res | Where-Object { $null -ne $_.PSObject.Properties['IPAddress'] } | Select-Object -First 1
    $src = $route
    if (-not $src) { $src = $addr }
    if (-not $src) { return $null }
    $source = $null
    if ($addr) { $source = [string]$addr.IPAddress }
    $nextHop = $null
    if ($route) { $nextHop = [string]$route.NextHop }
    [pscustomobject]@{
        InterfaceIndex = [int]$src.InterfaceIndex
        Alias          = [string]$src.InterfaceAlias
        SourceAddress  = $source
        NextHop        = $nextHop
    }
}

function Get-NisEffectiveOrder {
    <# Interfaces disposant d'une route par défaut, triées par métrique totale (la plus prioritaire d'abord). #>
    [CmdletBinding()]
    param([object[]]$States = @())
    $States | Where-Object { $null -ne $_ -and $null -ne $_.EffectiveMetric } |
        Sort-Object -Property @{ Expression = { $_.EffectiveMetric } }, @{ Expression = { $_.InterfaceIndex } }
}

# ---------------------------------------------------------------------------
# Ordre choisi (vue Simple) et calcul automatique des métriques
# ---------------------------------------------------------------------------

function Merge-NisOrder {
    <#
      Combine l'ordre sauvegardé et les interfaces présentes.
      - les interfaces sauvegardées gardent leur rang, même déconnectées ou absentes ;
      - les nouvelles interfaces sont ajoutées à la fin, dans l'ordre de priorité actuel de Windows.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$SavedOrder = @(),
        [AllowEmptyCollection()][object[]]$States = @(),
        # Masque les cartes présentes non utilisables (virtuelles) au lieu de les afficher comme absentes
        [switch]$UsableOnly
    )
    $States = @($States | Where-Object { $null -ne $_ })
    if ($UsableOnly) {
        $all = @(Merge-NisOrder -SavedOrder $SavedOrder -States $States)
        return ($all | Where-Object { -not $_.Present -or $_.State.IsUsable })
    }
    $used = @{}
    $keys = @{}
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($saved in @($SavedOrder | Where-Object { $null -ne $_ })) {
        $savedGuid = [string]$saved.Guid
        $savedAlias = [string]$saved.Alias
        $match = $null
        if ($savedGuid) {
            $match = $States | Where-Object { $_.Guid -and $_.Guid -eq $savedGuid -and -not $used.ContainsKey($_.Key) } | Select-Object -First 1
        }
        if (-not $match -and $savedAlias) {
            $match = $States | Where-Object { $_.Alias -eq $savedAlias -and -not $used.ContainsKey($_.Key) -and (-not $savedGuid -or -not $_.Guid) } | Select-Object -First 1
        }
        if ($match) {
            $used[$match.Key] = $true
            $keys[$match.Key] = $true
            $result.Add([pscustomobject]@{ Key = $match.Key; Alias = $match.Alias; Guid = $match.Guid; Kind = $match.Kind; Present = $true; State = $match })
        } else {
            $key = Get-NisEntryKey -Guid $savedGuid -Alias $savedAlias
            if ($keys.ContainsKey($key) -or -not ($savedGuid -or $savedAlias)) { continue }
            $keys[$key] = $true
            $kind = [string]$saved.Kind
            if (-not $kind) { $kind = 'Autre' }
            $guidValue = $null
            if ($savedGuid) { $guidValue = $savedGuid }
            $result.Add([pscustomobject]@{ Key = $key; Alias = $savedAlias; Guid = $guidValue; Kind = $kind; Present = $false; State = $null })
        }
    }

    $remaining = $States | Where-Object { -not $used.ContainsKey($_.Key) } | Sort-Object -Property `
        @{ Expression = { if ($null -ne $_.EffectiveMetric) { 0 } else { 1 } } },
        @{ Expression = { if ($null -ne $_.EffectiveMetric) { $_.EffectiveMetric } else { $_.InterfaceMetric } } },
        @{ Expression = { $_.InterfaceIndex } }
    foreach ($s in @($remaining)) {
        if ($keys.ContainsKey($s.Key)) { continue }
        $keys[$s.Key] = $true
        $result.Add([pscustomobject]@{ Key = $s.Key; Alias = $s.Alias; Guid = $s.Guid; Kind = $s.Kind; Present = $true; State = $s })
    }
    $result.ToArray()
}

function Move-NisListItem {
    <# Renvoie une copie de la liste avec l'élément $From déplacé à la position $To. #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Items = @(),
        [int]$From,
        [int]$To
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Items) { $list.Add($i) }
    if ($From -lt 0 -or $From -ge $list.Count) { return $list.ToArray() }
    if ($To -lt 0) { $To = 0 }
    if ($To -ge $list.Count) { $To = $list.Count - 1 }
    if ($From -eq $To) { return $list.ToArray() }
    $item = $list[$From]
    $list.RemoveAt($From)
    $list.Insert($To, $item)
    $list.ToArray()
}

function Get-NisPriorityPlan {
    <#
      Calcule les métriques pour N interfaces ordonnées (rang 1 = la plus prioritaire) :
        métrique d'interface = BaseMetric + (rang - 1) * Step      -> 10, 20, 30, ...
        métrique de route    = (rang - 1) * RouteStep              -> 0, 10, 20, ...
        métrique totale      = somme                               -> 10, 30, 50, ...
      Le rang des interfaces absentes est conservé (leur place reste réservée).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Entries = @(),
        [int]$BaseMetric = 10,
        [int]$Step = 10,
        [int]$RouteStep = 10
    )
    $rank = 0
    foreach ($e in @($Entries | Where-Object { $null -ne $_ })) {
        $rank++
        $ifMetric = $BaseMetric + ($rank - 1) * $Step
        $routeMetric = ($rank - 1) * $RouteStep
        $index = $null
        if ($e.Present -and $e.State) { $index = [int]$e.State.InterfaceIndex }
        [pscustomobject]@{
            Rank            = $rank
            Key             = $e.Key
            Alias           = $e.Alias
            Present         = [bool]$e.Present
            InterfaceIndex  = $index
            State           = $e.State
            InterfaceMetric = $ifMetric
            RouteMetric     = $routeMetric
            TotalMetric     = $ifMetric + $routeMetric
        }
    }
}

# ---------------------------------------------------------------------------
# Réglages voulus (Desired) et validation
# ---------------------------------------------------------------------------

function New-NisDesiredSetting {
    <# Réglages voulus pour une interface. $null = ne pas modifier ce paramètre. #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructeur d''objet, ne modifie pas le système')]
    param(
        [Parameter(Mandatory = $true)][int]$InterfaceIndex,
        [string]$Alias,
        $AutomaticMetric = $null,
        $InterfaceMetric = $null,
        $RouteMetric = $null,
        $IPv6Enabled = $null,
        $IPv6AutomaticMetric = $null,
        $IPv6InterfaceMetric = $null
    )
    [pscustomobject]@{
        InterfaceIndex      = $InterfaceIndex
        Alias               = $Alias
        AutomaticMetric     = $AutomaticMetric
        InterfaceMetric     = $InterfaceMetric
        RouteMetric         = $RouteMetric
        IPv6Enabled         = $IPv6Enabled
        IPv6AutomaticMetric = $IPv6AutomaticMetric
        IPv6InterfaceMetric = $IPv6InterfaceMetric
    }
}

function ConvertTo-NisMetric {
    <# Convertit un texte saisi en métrique entière. Renvoie @{ Value; Error }. #>
    [CmdletBinding()]
    param([string]$Text, [int]$Min = 0, [int]$Max = 9999, [string]$Label = 'métrique')
    $t = ''
    if ($null -ne $Text) { $t = $Text.Trim() }
    $n = 0
    if (-not [int]::TryParse($t, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return @{ Value = $null; Error = "$Label : '$t' n'est pas un nombre entier positif" }
    }
    if ($n -lt $Min -or $n -gt $Max) {
        return @{ Value = $null; Error = "$Label : $n hors limites ($Min à $Max)" }
    }
    return @{ Value = $n; Error = $null }
}

function ConvertTo-NisDesiredFromInput {
    <#
      Traduit une ligne de la vue Avancé (valeurs saisies) en réglages voulus.
      Renvoie @{ Desired; Errors }.
        InterfaceMetricText : ignoré si AutomaticMetric
        RouteMetricText     : vide = ne pas toucher ; ignoré si pas de route par défaut
        IPv6MetricText      : vide = automatique ; ignoré si pas d'interface IPv6 ou IPv6 désactivé
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $State,
        [bool]$AutomaticMetric,
        [string]$InterfaceMetricText,
        [string]$RouteMetricText,
        $IPv6Enabled = $null,
        [string]$IPv6MetricText
    )
    $errors = @()
    $alias = $State.Alias
    $ifMetric = $null
    if (-not $AutomaticMetric) {
        $r = ConvertTo-NisMetric -Text $InterfaceMetricText -Min $script:NisMinInterfaceMetric -Max $script:NisMaxMetric -Label "$alias - métrique d'interface"
        if ($r.Error) { $errors += $r.Error } else { $ifMetric = $r.Value }
    }
    $routeMetric = $null
    if (@($State.Routes).Count -gt 0 -and $RouteMetricText -and $RouteMetricText.Trim()) {
        $r = ConvertTo-NisMetric -Text $RouteMetricText -Min 0 -Max $script:NisMaxMetric -Label "$alias - métrique de route"
        if ($r.Error) { $errors += $r.Error } else { $routeMetric = $r.Value }
    }
    $v6Enabled = $null
    if ($null -ne $State.IPv6Enabled -and $null -ne $IPv6Enabled) { $v6Enabled = [bool]$IPv6Enabled }
    $v6Auto = $null
    $v6Metric = $null
    $v6WillBeOn = ($null -eq $v6Enabled -or $v6Enabled)
    if ($State.HasIPv6Interface -and $v6WillBeOn) {
        if ($IPv6MetricText -and $IPv6MetricText.Trim()) {
            $r = ConvertTo-NisMetric -Text $IPv6MetricText -Min $script:NisMinInterfaceMetric -Max $script:NisMaxMetric -Label "$alias - métrique IPv6"
            if ($r.Error) { $errors += $r.Error } else { $v6Auto = $false; $v6Metric = $r.Value }
        } else {
            $v6Auto = $true
        }
    }
    $desired = New-NisDesiredSetting -InterfaceIndex $State.InterfaceIndex -Alias $alias `
        -AutomaticMetric ([bool]$AutomaticMetric) -InterfaceMetric $ifMetric -RouteMetric $routeMetric `
        -IPv6Enabled $v6Enabled -IPv6AutomaticMetric $v6Auto -IPv6InterfaceMetric $v6Metric
    return @{ Desired = $desired; Errors = $errors }
}

function ConvertTo-NisDesiredFromPlan {
    <# Réglages voulus pour les interfaces présentes d'un plan de priorité (vue Simple). #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Plan = @(),
        [switch]$IncludeIPv6
    )
    foreach ($p in @($Plan | Where-Object { $null -ne $_ -and $_.Present -and $null -ne $_.InterfaceIndex })) {
        $v6Auto = $null
        $v6Metric = $null
        if ($IncludeIPv6 -and $p.State -and $p.State.HasIPv6Interface) {
            $v6Auto = $false
            $v6Metric = $p.InterfaceMetric
        }
        New-NisDesiredSetting -InterfaceIndex $p.InterfaceIndex -Alias $p.Alias -AutomaticMetric $false `
            -InterfaceMetric $p.InterfaceMetric -RouteMetric $p.RouteMetric `
            -IPv6AutomaticMetric $v6Auto -IPv6InterfaceMetric $v6Metric
    }
}

function Get-NisResetDesired {
    <# Retour au comportement Windows : métriques automatiques (IPv4 et IPv6), métriques de route à 0. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$States = @())
    foreach ($s in @($States | Where-Object { $null -ne $_ })) {
        $v6Auto = $null
        if ($s.HasIPv6Interface) { $v6Auto = $true }
        New-NisDesiredSetting -InterfaceIndex $s.InterfaceIndex -Alias $s.Alias -AutomaticMetric $true -RouteMetric 0 -IPv6AutomaticMetric $v6Auto
    }
}

function Get-NisForceOneDesired {
    <# Ancien mode « une seule interface prioritaire » : elle passe à 10 + 0, les autres à 1000 + 1000. #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$States = @(),
        [Parameter(Mandatory = $true)][int]$InterfaceIndex
    )
    foreach ($s in @($States | Where-Object { $null -ne $_ })) {
        if ($s.InterfaceIndex -eq $InterfaceIndex) {
            New-NisDesiredSetting -InterfaceIndex $s.InterfaceIndex -Alias $s.Alias -AutomaticMetric $false -InterfaceMetric 10 -RouteMetric 0
        } elseif ($s.IsUsable) {
            New-NisDesiredSetting -InterfaceIndex $s.InterfaceIndex -Alias $s.Alias -AutomaticMetric $false -InterfaceMetric 1000 -RouteMetric 1000
        }
    }
}

function Test-NisDesiredSettings {
    <# Vérifie TOUS les réglages voulus avant toute modification. Renvoie la liste des erreurs (vide = OK). #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Desired = @(),
        [AllowEmptyCollection()][object[]]$States = @()
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $byIndex = @{}
    foreach ($s in @($States | Where-Object { $null -ne $_ })) { $byIndex[[int]$s.InterfaceIndex] = $s }
    $seen = @{}
    foreach ($d in @($Desired | Where-Object { $null -ne $_ })) {
        $idx = [int]$d.InterfaceIndex
        $name = $d.Alias
        if (-not $name) { $name = "interface $idx" }
        if ($seen.ContainsKey($idx)) { $errors.Add("$name : interface présente deux fois"); continue }
        $seen[$idx] = $true
        if (-not $byIndex.ContainsKey($idx)) { $errors.Add("$name : interface introuvable (débranchée ou renommée ?) - rafraîchissez la liste"); continue }
        $s = $byIndex[$idx]
        if ($null -ne $d.AutomaticMetric -and -not [bool]$d.AutomaticMetric) {
            if ($null -eq $d.InterfaceMetric) {
                $errors.Add("$name : métrique d'interface manquante (métrique automatique désactivée)")
            } elseif (-not ($d.InterfaceMetric -is [int]) -or $d.InterfaceMetric -lt $script:NisMinInterfaceMetric -or $d.InterfaceMetric -gt $script:NisMaxMetric) {
                $errors.Add("$name : métrique d'interface $($d.InterfaceMetric) hors limites ($script:NisMinInterfaceMetric à $script:NisMaxMetric)")
            }
        }
        if ($null -ne $d.RouteMetric -and (-not ($d.RouteMetric -is [int]) -or $d.RouteMetric -lt 0 -or $d.RouteMetric -gt $script:NisMaxMetric)) {
            $errors.Add("$name : métrique de route $($d.RouteMetric) hors limites (0 à $script:NisMaxMetric)")
        }
        if ($null -ne $d.IPv6Enabled -and $null -eq $s.IPv6Enabled) {
            $errors.Add("$name : la liaison IPv6 de cette carte n'est pas modifiable")
        }
        if ($null -ne $d.IPv6AutomaticMetric) {
            if (-not $s.HasIPv6Interface) {
                $errors.Add("$name : pas d'interface IPv6 active (réactivez IPv6, appliquez, puis réglez la métrique IPv6)")
            } elseif (-not [bool]$d.IPv6AutomaticMetric) {
                if ($null -eq $d.IPv6InterfaceMetric) {
                    $errors.Add("$name : métrique IPv6 manquante")
                } elseif (-not ($d.IPv6InterfaceMetric -is [int]) -or $d.IPv6InterfaceMetric -lt $script:NisMinInterfaceMetric -or $d.IPv6InterfaceMetric -gt $script:NisMaxMetric) {
                    $errors.Add("$name : métrique IPv6 $($d.IPv6InterfaceMetric) hors limites ($script:NisMinInterfaceMetric à $script:NisMaxMetric)")
                }
            }
        }
    }
    $errors.ToArray()
}

# ---------------------------------------------------------------------------
# Différences entre l'état actuel et les réglages voulus
# ---------------------------------------------------------------------------

function New-NisMetricValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructeur d''objet')]
    param([bool]$Automatic, $Metric)
    [pscustomobject]@{ Automatic = $Automatic; Metric = $Metric }
}

function Get-NisChangeSet {
    <#
      Liste ordonnée des modifications nécessaires (uniquement ce qui change).
      Ordre : métriques IPv4, routes, activation IPv6, métriques IPv6, désactivation IPv6.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Desired = @(),
        [AllowEmptyCollection()][object[]]$States = @()
    )
    $byIndex = @{}
    foreach ($s in @($States | Where-Object { $null -ne $_ })) { $byIndex[[int]$s.InterfaceIndex] = $s }
    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($d in @($Desired | Where-Object { $null -ne $_ })) {
        $s = $byIndex[[int]$d.InterfaceIndex]
        if (-not $s) { continue }
        $base = @{ InterfaceIndex = $s.InterfaceIndex; Alias = $s.Alias; NextHop = $null }

        if ($null -ne $d.AutomaticMetric) {
            $wantAuto = [bool]$d.AutomaticMetric
            $differs = ($wantAuto -ne $s.AutomaticMetric) -or ((-not $wantAuto) -and ($d.InterfaceMetric -ne $s.InterfaceMetric))
            if ($differs) {
                $to = New-NisMetricValue -Automatic $wantAuto -Metric $(if ($wantAuto) { $null } else { [int]$d.InterfaceMetric })
                $actions.Add((New-Object PSObject -Property (@{ Phase = 1; Type = 'IPv4Metric'; From = (New-NisMetricValue -Automatic $s.AutomaticMetric -Metric $s.InterfaceMetric); To = $to } + $base)))
            }
        }
        if ($null -ne $d.RouteMetric) {
            foreach ($r in @($s.Routes)) {
                if ([int]$r.RouteMetric -ne [int]$d.RouteMetric) {
                    $a = @{ Phase = 2; Type = 'RouteMetric'; From = [int]$r.RouteMetric; To = [int]$d.RouteMetric } + $base
                    $a.NextHop = $r.NextHop
                    $actions.Add((New-Object PSObject -Property $a))
                }
            }
        }
        if ($null -ne $d.IPv6Enabled -and $null -ne $s.IPv6Enabled -and [bool]$d.IPv6Enabled -ne [bool]$s.IPv6Enabled) {
            $phase = 5
            if ([bool]$d.IPv6Enabled) { $phase = 3 }
            $actions.Add((New-Object PSObject -Property (@{ Phase = $phase; Type = 'IPv6Binding'; From = [bool]$s.IPv6Enabled; To = [bool]$d.IPv6Enabled } + $base)))
        }
        if ($null -ne $d.IPv6AutomaticMetric -and $s.HasIPv6Interface) {
            $wantAuto = [bool]$d.IPv6AutomaticMetric
            $differs = ($wantAuto -ne [bool]$s.IPv6AutomaticMetric) -or ((-not $wantAuto) -and ($d.IPv6InterfaceMetric -ne $s.IPv6InterfaceMetric))
            if ($differs) {
                $to = New-NisMetricValue -Automatic $wantAuto -Metric $(if ($wantAuto) { $null } else { [int]$d.IPv6InterfaceMetric })
                $actions.Add((New-Object PSObject -Property (@{ Phase = 4; Type = 'IPv6Metric'; From = (New-NisMetricValue -Automatic ([bool]$s.IPv6AutomaticMetric) -Metric $s.IPv6InterfaceMetric); To = $to } + $base)))
            }
        }
    }
    # Tri stable par phase (on garde l'ordre des interfaces à l'intérieur d'une phase)
    $i = 0
    $indexed = foreach ($a in $actions) { $i++; [pscustomobject]@{ N = $i; A = $a } }
    @($indexed) | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { $_.A.Phase } }, @{ Expression = { $_.N } } | ForEach-Object { $_.A }
}

function Format-NisMetricValue {
    param($Value)
    if ($Value.Automatic) {
        if ($null -ne $Value.Metric) { return "auto ($($Value.Metric))" }
        return 'auto'
    }
    return [string]$Value.Metric
}

function Format-NisAction {
    <# Description lisible d'une modification (pour la confirmation et le journal). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Action)
    switch ($Action.Type) {
        'IPv4Metric' { return "$($Action.Alias) : métrique d'interface IPv4 $(Format-NisMetricValue $Action.From) -> $(Format-NisMetricValue $Action.To)" }
        'IPv6Metric' { return "$($Action.Alias) : métrique d'interface IPv6 $(Format-NisMetricValue $Action.From) -> $(Format-NisMetricValue $Action.To)" }
        'RouteMetric' { return "$($Action.Alias) : métrique de route $script:NisDefaultRoutePrefix via $($Action.NextHop) $($Action.From) -> $($Action.To)" }
        'IPv6Binding' {
            $f = 'désactivé'; if ($Action.From) { $f = 'activé' }
            $t = 'désactivé'; if ($Action.To) { $t = 'activé' }
            return "$($Action.Alias) : IPv6 $f -> $t"
        }
    }
    return "$($Action.Alias) : $($Action.Type)"
}

# ---------------------------------------------------------------------------
# Application des modifications (avec annulation en cas d'erreur)
# ---------------------------------------------------------------------------

function Invoke-NisAction {
    <# Applique une modification (ou la défait avec -Undo). Lève une exception en cas d'échec. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Action, [switch]$Undo)
    $value = $Action.To
    if ($Undo) { $value = $Action.From }
    $idx = [int]$Action.InterfaceIndex
    switch ($Action.Type) {
        { $_ -eq 'IPv4Metric' -or $_ -eq 'IPv6Metric' } {
            $family = 'IPv4'
            if ($Action.Type -eq 'IPv6Metric') { $family = 'IPv6' }
            if ($value.Automatic) {
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily $family -AutomaticMetric Enabled -ErrorAction Stop
            } else {
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily $family -AutomaticMetric Disabled -InterfaceMetric ([int]$value.Metric) -ErrorAction Stop
            }
        }
        'RouteMetric' {
            $routes = @(Get-NetRoute -DestinationPrefix $script:NisDefaultRoutePrefix -InterfaceIndex $idx -NextHop $Action.NextHop -AddressFamily IPv4 -ErrorAction Stop)
            if ($routes.Count -eq 0) { throw "route par défaut via $($Action.NextHop) introuvable" }
            $routes | Set-NetRoute -RouteMetric ([int]$value) -ErrorAction Stop
        }
        'IPv6Binding' {
            if ($value) {
                Enable-NetAdapterBinding -Name $Action.Alias -ComponentID ms_tcpip6 -ErrorAction Stop
            } else {
                Disable-NetAdapterBinding -Name $Action.Alias -ComponentID ms_tcpip6 -ErrorAction Stop
            }
        }
        default { throw "type de modification inconnu : $($Action.Type)" }
    }
}

function Invoke-NisChangeSet {
    <#
      Applique les modifications dans l'ordre. A la première erreur, défait toutes celles
      déjà appliquées (dans l'ordre inverse) pour ne jamais laisser le système à moitié configuré.
      -Log : scriptblock appelé avec chaque message de journal.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Actions = @(),
        [scriptblock]$Log
    )
    $done = New-Object System.Collections.Generic.List[object]
    $details = New-Object System.Collections.Generic.List[object]
    $failed = $null
    $errorMessage = $null
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    $Actions = @($Actions | Where-Object { $null -ne $_ })

    foreach ($a in $Actions) {
        $text = Format-NisAction -Action $a
        try {
            Invoke-NisAction -Action $a
            $done.Add($a)
            $details.Add([pscustomobject]@{ Action = $a; Status = 'Applied'; Message = $null })
            if ($Log) { & $Log "OK     $text" }
        } catch {
            $failed = $a
            $errorMessage = $_.Exception.Message
            $details.Add([pscustomobject]@{ Action = $a; Status = 'Failed'; Message = $errorMessage })
            if ($Log) { & $Log "ECHEC  $text : $errorMessage" }
            break
        }
    }

    if ($failed) {
        if ($Log -and $done.Count -gt 0) { & $Log "Annulation des $($done.Count) modification(s) déjà appliquée(s)..." }
        for ($i = $done.Count - 1; $i -ge 0; $i--) {
            $a = $done[$i]
            $detail = $details | Where-Object { [object]::ReferenceEquals($_.Action, $a) } | Select-Object -First 1
            try {
                Invoke-NisAction -Action $a -Undo
                $detail.Status = 'RolledBack'
                if ($Log) { & $Log "ANNULE $(Format-NisAction -Action $a)" }
            } catch {
                $detail.Status = 'RollbackFailed'
                $detail.Message = $_.Exception.Message
                $rollbackErrors.Add("$(Format-NisAction -Action $a) : $($_.Exception.Message)")
                if ($Log) { & $Log "ECHEC de l'annulation : $(Format-NisAction -Action $a) : $($_.Exception.Message)" }
            }
        }
        $started = $false
        foreach ($a in $Actions) {
            if ([object]::ReferenceEquals($a, $failed)) { $started = $true; continue }
            if ($started) { $details.Add([pscustomobject]@{ Action = $a; Status = 'Skipped'; Message = $null }) }
        }
    }

    [pscustomobject]@{
        Success        = ($null -eq $failed)
        AppliedCount   = $done.Count
        FailedAction   = $failed
        ErrorMessage   = $errorMessage
        RollbackErrors = $rollbackErrors.ToArray()
        Details        = $details.ToArray()
    }
}

function Format-NisResultReport {
    <# Compte rendu par interface d'un Invoke-NisChangeSet. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Result)
    $lines = New-Object System.Collections.Generic.List[string]
    # Regroupement par interface, dans l'ordre d'apparition (Group-Object trierait par nom)
    $byAlias = [ordered]@{}
    foreach ($d in @($Result.Details | Where-Object { $null -ne $_ })) {
        $name = [string]$d.Action.Alias
        if (-not $byAlias.Contains($name)) { $byAlias[$name] = New-Object System.Collections.Generic.List[object] }
        $byAlias[$name].Add($d)
    }
    foreach ($name in $byAlias.Keys) {
        $g = [pscustomobject]@{ Name = $name; Group = $byAlias[$name].ToArray() }
        $statuses = @($g.Group | ForEach-Object { $_.Status })
        if ($statuses -contains 'Failed') {
            $msg = ($g.Group | Where-Object { $_.Status -eq 'Failed' } | Select-Object -First 1).Message
            $lines.Add("$($g.Name) : ÉCHEC - $msg")
        } elseif ($statuses -contains 'RollbackFailed') {
            $lines.Add("$($g.Name) : ATTENTION - annulation incomplète, vérifiez cette interface")
        } elseif ($statuses -contains 'RolledBack') {
            $lines.Add("$($g.Name) : modifications annulées (retour à l'état initial)")
        } elseif ($statuses -contains 'Skipped') {
            $lines.Add("$($g.Name) : non modifiée (application interrompue)")
        } else {
            $lines.Add("$($g.Name) : OK ($($statuses.Count) modification(s))")
        }
    }
    $lines.ToArray()
}

# ---------------------------------------------------------------------------
# Persistance de l'ordre choisi (%APPDATA%\network-iface-switch\order.json)
# ---------------------------------------------------------------------------

function Get-NisOrderFilePath {
    [CmdletBinding()]
    param()
    $root = $env:APPDATA
    if (-not $root) { $root = $HOME }
    Join-Path (Join-Path $root 'network-iface-switch') 'order.json'
}

function Read-NisOrder {
    <# Lit l'ordre sauvegardé. Fichier absent ou illisible -> ordre vide. #>
    [CmdletBinding()]
    param([string]$Path = (Get-NisOrderFilePath))
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Ordre sauvegardé illisible ($Path) : $($_.Exception.Message)"
        return
    }
    foreach ($e in @($data.order)) {
        if ($null -eq $e) { continue }
        [pscustomobject]@{ Alias = [string]$e.Alias; Guid = [string]$e.Guid; Kind = [string]$e.Kind }
    }
}

function Save-NisOrder {
    <# Sauvegarde l'ordre (liste d'entrées) de façon atomique. #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [AllowEmptyCollection()][object[]]$Entries = @(),
        [string]$Path = (Get-NisOrderFilePath)
    )
    $dir = Split-Path -Parent $Path
    if (-not $PSCmdlet.ShouldProcess($Path, 'Sauvegarder l''ordre des interfaces')) { return }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $order = @(foreach ($e in @($Entries | Where-Object { $null -ne $_ })) {
            [ordered]@{ Alias = [string]$e.Alias; Guid = [string]$e.Guid; Kind = [string]$e.Kind }
        })
    $data = [ordered]@{ version = 1; savedAt = (Get-Date).ToString('s'); order = $order }
    $json = ConvertTo-Json -InputObject $data -Depth 5
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Clear-NisOrder {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path = (Get-NisOrderFilePath))
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Supprimer l''ordre sauvegardé')) {
        Remove-Item -LiteralPath $Path -Force
    }
}
