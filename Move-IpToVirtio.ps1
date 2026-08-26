#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Moves IPv4 and IPv6 configuration from a non-VirtIO NIC to a VirtIO NIC sharing the same MAC.

.DESCRIPTION
    Finds pairs of adapters with matching MAC addresses where one is VirtIO and
    the other is not. Copies all IPv4 and IPv6 addresses, default gateways, and
    DNS servers from the non-VirtIO adapter to the VirtIO adapter, then removes
    the old adapter from the system.

    Link-local addresses (169.254.x.x and fe80::) are left alone — Windows will
    generate those automatically on the new adapter.

    Covers any scenario where a VirtIO NIC has been added alongside an existing
    adapter with the same MAC address:
      - V2V: VMware to Proxmox (E1000/E1000E/VMXNET3 to VirtIO)
      - P2V: Physical to Proxmox (Intel/Broadcom/Realtek to VirtIO)
      - Driver swap: Replacing any emulated NIC with VirtIO post-import

.PARAMETER RemoveOld
    Removes the non-VirtIO adapter from the system after migration. Default: $true.

.EXAMPLE
    .\Move-IpToVirtio.ps1
    .\Move-IpToVirtio.ps1 -RemoveOld:$false
#>

[CmdletBinding()]
param(
    [bool]$RemoveOld = $true
)

$virtioAdapters = Get-NetAdapter | Where-Object {
    $_.InterfaceDescription -like '*VirtIO*' -or $_.DriverDescription -like '*VirtIO*'
}

if (-not $virtioAdapters) {
    Write-Error "No VirtIO adapters found on this system."
    exit 1
}

$moved = 0

foreach ($virtio in $virtioAdapters) {
    $mac = $virtio.MacAddress

    # Find the non-VirtIO adapter with the same MAC
    $oldNic = Get-NetAdapter | Where-Object {
        $_.MacAddress -eq $mac -and
        $_.ifIndex -ne $virtio.ifIndex -and
        $_.InterfaceDescription -notlike '*VirtIO*' -and
        $_.DriverDescription -notlike '*VirtIO*'
    }

    if (-not $oldNic) {
        Write-Host "VirtIO adapter '$($virtio.Name)' ($mac) — no matching non-VirtIO NIC found, skipping." -ForegroundColor DarkGray
        continue
    }

    if ($oldNic.Count -gt 1) {
        Write-Warning "Multiple non-VirtIO adapters share MAC $mac — using '$($oldNic[0].Name)'."
        $oldNic = $oldNic[0]
    }

    $oldIndex = $oldNic.ifIndex
    $newIndex = $virtio.ifIndex

    Write-Host "`nMoving config: '$($oldNic.Name)' ($($oldNic.InterfaceDescription)) -> '$($virtio.Name)' ($($virtio.InterfaceDescription))" -ForegroundColor Cyan
    Write-Host "  MAC: $mac"

    # ── Detect DHCP / automatic config ────────────────────────────────────

    # Gather all non-link-local addresses first
    $rawV4 = Get-NetIPAddress -InterfaceIndex $oldIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' }

    $rawV6 = Get-NetIPAddress -InterfaceIndex $oldIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike 'fe80::*' -and $_.PrefixOrigin -ne 'WellKnown' }

    # ── Exclude non-production addresses with warnings ─────────────────────
    #
    # IPv4 exclusions:
    #   0.0.0.0/8        "This network"              RFC 791
    #   127.0.0.0/8      Loopback                    RFC 1122
    #   192.0.0.0/24     IETF protocol assignments   RFC 6890
    #   192.0.2.0/24     TEST-NET-1                  RFC 5737
    #   192.88.99.0/24   6to4 relay anycast          RFC 7526 (deprecated)
    #   198.18.0.0/15    Benchmarking                RFC 2544
    #   198.51.100.0/24  TEST-NET-2                  RFC 5737
    #   203.0.113.0/24   TEST-NET-3                  RFC 5737
    #   224.0.0.0/4      Multicast                   RFC 5771
    #   240.0.0.0/4      Reserved / future use       RFC 1112
    #
    # IPv6 exclusions:
    #   ::/128           Unspecified                  RFC 4291
    #   ::1/128          Loopback                    RFC 4291
    #   ::ffff:0:0/96    IPv4-mapped                 RFC 4291
    #   64:ff9b::/96     NAT64 well-known prefix     RFC 6052
    #   64:ff9b:1::/48   NAT64 local-use prefix      RFC 8215
    #   100::/64         Discard-only                RFC 6666
    #   2001:db8::/32    Documentation               RFC 3849
    #   2001:10::/28     ORCHID (deprecated)         RFC 4843
    #   2001:20::/28     ORCHIDv2 (experimental)     RFC 7343
    #   2002::/16        6to4 (deprecated)           RFC 7526
    #   3ffe::/16        6bone (decommissioned)      RFC 3701
    #   5f00::/16        SRv6 SID                    RFC 9602
    #   ff00::/8         Multicast                   RFC 4291

    # Build exclusion rules: pattern/test, label, RFC
    $v4Exclusions = @(
        @{ Match = { $_.IPAddress -like '0.*' };            Label = '"this network" (0.0.0.0/8)';             RFC = 'RFC 791' }
        @{ Match = { $_.IPAddress -like '127.*' };          Label = 'loopback (127.0.0.0/8)';                 RFC = 'RFC 1122' }
        @{ Match = { $_.IPAddress -like '192.0.0.*' };      Label = 'IETF protocol assignments (192.0.0.0/24)'; RFC = 'RFC 6890' }
        @{ Match = { $_.IPAddress -like '192.0.2.*' };      Label = 'TEST-NET-1 (192.0.2.0/24)';              RFC = 'RFC 5737' }
        @{ Match = { $_.IPAddress -like '192.88.99.*' };    Label = '6to4 relay anycast (192.88.99.0/24)';    RFC = 'RFC 7526' }
        @{ Match = { $_.IPAddress -like '198.18.*' -or $_.IPAddress -like '198.19.*' }; Label = 'benchmarking (198.18.0.0/15)'; RFC = 'RFC 2544' }
        @{ Match = { $_.IPAddress -like '198.51.100.*' };   Label = 'TEST-NET-2 (198.51.100.0/24)';           RFC = 'RFC 5737' }
        @{ Match = { $_.IPAddress -like '203.0.113.*' };    Label = 'TEST-NET-3 (203.0.113.0/24)';            RFC = 'RFC 5737' }
        @{ Match = { [int]($_.IPAddress.Split('.')[0]) -ge 224 -and [int]($_.IPAddress.Split('.')[0]) -le 239 }; Label = 'multicast (224.0.0.0/4)'; RFC = 'RFC 5771' }
        @{ Match = { [int]($_.IPAddress.Split('.')[0]) -ge 240 }; Label = 'reserved / future use (240.0.0.0/4)'; RFC = 'RFC 1112' }
    )

    $v6Exclusions = @(
        @{ Match = { $_.IPAddress -eq '::' };               Label = 'unspecified address (::)';               RFC = 'RFC 4291' }
        @{ Match = { $_.IPAddress -eq '::1' };              Label = 'loopback (::1)';                         RFC = 'RFC 4291' }
        @{ Match = { $_.IPAddress -like '::ffff:*' };       Label = 'IPv4-mapped (::ffff:0:0/96)';            RFC = 'RFC 4291' }
        @{ Match = { $_.IPAddress -like '64:ff9b:*' };      Label = 'NAT64 well-known prefix (64:ff9b::/96)'; RFC = 'RFC 6052' }
        @{ Match = { $_.IPAddress -like '100::*' -or $_.IPAddress -eq '100::' }; Label = 'discard-only (100::/64)'; RFC = 'RFC 6666' }
        @{ Match = { $_.IPAddress -like '2001:db8:*' };     Label = 'documentation (2001:db8::/32)';          RFC = 'RFC 3849' }
        @{ Match = { $_.IPAddress -like '2001:10:*' };      Label = 'ORCHID deprecated (2001:10::/28)';       RFC = 'RFC 4843' }
        @{ Match = { $_.IPAddress -like '2001:20:*' };      Label = 'ORCHIDv2 experimental (2001:20::/28)';   RFC = 'RFC 7343' }
        @{ Match = { $_.IPAddress -like '2002:*' };         Label = '6to4 deprecated (2002::/16)';            RFC = 'RFC 7526' }
        @{ Match = { $_.IPAddress -like '3ffe:*' };         Label = '6bone decommissioned (3ffe::/16)';       RFC = 'RFC 3701' }
        @{ Match = { $_.IPAddress -like '5f00:*' };         Label = 'SRv6 SID block (5f00::/16)';             RFC = 'RFC 9602' }
        @{ Match = { $_.IPAddress -like 'ff*:*' -and $_.IPAddress -notlike 'fe*' }; Label = 'multicast (ff00::/8)'; RFC = 'RFC 4291' }
    )

    $excludedV4 = @()
    foreach ($addr in $rawV4) {
        foreach ($rule in $v4Exclusions) {
            if ($addr | Where-Object $rule.Match) {
                Write-Warning "  Skipping $($addr.IPAddress) — $($rule.Label), $($rule.RFC)."
                $excludedV4 += $addr.IPAddress
                break
            }
        }
    }

    $excludedV6 = @()
    foreach ($addr in $rawV6) {
        foreach ($rule in $v6Exclusions) {
            if ($addr | Where-Object $rule.Match) {
                Write-Warning "  Skipping $($addr.IPAddress) — $($rule.Label), $($rule.RFC)."
                $excludedV6 += $addr.IPAddress
                break
            }
        }
    }

    $allV4 = $rawV4 | Where-Object { $_.IPAddress -notin $excludedV4 }
    $allV6 = $rawV6 | Where-Object { $_.IPAddress -notin $excludedV6 }

    # IPv4: skip if all addresses are DHCP — the VirtIO NIC will pick up a lease itself
    $skipV4 = $false
    $v4Addresses = $null
    if ($allV4) {
        $staticV4 = $allV4 | Where-Object { $_.PrefixOrigin -eq 'Manual' }
        if (-not $staticV4) {
            Write-Host "  IPv4 is DHCP — skipping, the VirtIO adapter will get its own lease." -ForegroundColor DarkGray
            $skipV4 = $true
        } else {
            $v4Addresses = $staticV4
        }
    } else {
        $skipV4 = $true
    }

    # IPv6: skip if all addresses are automatic (SLAAC / DHCPv6)
    $skipV6 = $false
    $v6Addresses = $null
    if ($allV6) {
        $staticV6 = $allV6 | Where-Object { $_.PrefixOrigin -eq 'Manual' }
        if (-not $staticV6) {
            Write-Host "  IPv6 is automatic (SLAAC/DHCPv6) — skipping, the VirtIO adapter will configure itself." -ForegroundColor DarkGray
            $skipV6 = $true
        } else {
            $v6Addresses = $staticV6
        }
    } else {
        $skipV6 = $true
    }

    if ($skipV4 -and $skipV6) {
        Write-Host "  Both address families are dynamic — nowt to move." -ForegroundColor DarkGray
        continue
    }

    # ── Gather gateways and DNS for the families we're moving ──────────────

    $v4Gateway = $null; $v4Dns = $null
    $v6Gateway = $null; $v6Dns = $null

    if (-not $skipV4) {
        $v4Gateway = Get-NetRoute -InterfaceIndex $oldIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        $v4Dns     = Get-DnsClientServerAddress -InterfaceIndex $oldIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }

    if (-not $skipV6) {
        $v6Gateway = Get-NetRoute -InterfaceIndex $oldIndex -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
        $v6Dns     = Get-DnsClientServerAddress -InterfaceIndex $oldIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
    }

    # DNS suffixes are per-interface, not per address family
    $oldDnsClient = Get-DnsClient -InterfaceIndex $oldIndex -ErrorAction SilentlyContinue

    # ── Clear existing config on the VirtIO NIC ─────────────────────────────

    if (-not $skipV4) {
        Get-NetIPAddress -InterfaceIndex $newIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Get-NetRoute -InterfaceIndex $newIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (-not $skipV6) {
        Get-NetIPAddress -InterfaceIndex $newIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike 'fe80::*' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Get-NetRoute -InterfaceIndex $newIndex -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }

    # ── Remove config from the old NIC ──────────────────────────────────────

    if ($v4Addresses) { $v4Addresses | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }
    if ($v6Addresses) { $v6Addresses | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }
    if ($v4Gateway)   { $v4Gateway   | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }
    if ($v6Gateway)   { $v6Gateway   | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }

    # ── Apply IPv4 (static only) ────────────────────────────────────────────

    if (-not $skipV4) {
        foreach ($addr in $v4Addresses) {
            Write-Host "  IPv4: $($addr.IPAddress)/$($addr.PrefixLength)"
            New-NetIPAddress -InterfaceIndex $newIndex `
                             -IPAddress $addr.IPAddress `
                             -PrefixLength $addr.PrefixLength `
                             -ErrorAction Stop | Out-Null
        }

        if ($v4Gateway) {
            Write-Host "  IPv4 gateway: $($v4Gateway.NextHop)"
            New-NetRoute -InterfaceIndex $newIndex `
                         -DestinationPrefix '0.0.0.0/0' `
                         -NextHop $v4Gateway.NextHop `
                         -ErrorAction Stop | Out-Null
        }

        if ($v4Dns.ServerAddresses.Count -gt 0) {
            Write-Host "  IPv4 DNS: $($v4Dns.ServerAddresses -join ', ')"
            Set-DnsClientServerAddress -InterfaceIndex $newIndex `
                                       -ServerAddresses $v4Dns.ServerAddresses `
                                       -ErrorAction Stop
        }
    }

    # ── Apply IPv6 (static only) ────────────────────────────────────────────

    if (-not $skipV6) {
        foreach ($addr in $v6Addresses) {
            Write-Host "  IPv6: $($addr.IPAddress)/$($addr.PrefixLength)"
            New-NetIPAddress -InterfaceIndex $newIndex `
                             -IPAddress $addr.IPAddress `
                             -PrefixLength $addr.PrefixLength `
                             -ErrorAction Stop | Out-Null
        }

        if ($v6Gateway) {
            Write-Host "  IPv6 gateway: $($v6Gateway.NextHop)"
            New-NetRoute -InterfaceIndex $newIndex `
                         -DestinationPrefix '::/0' `
                         -NextHop $v6Gateway.NextHop `
                         -ErrorAction Stop | Out-Null
        }

        if ($v6Dns.ServerAddresses.Count -gt 0) {
            Write-Host "  IPv6 DNS: $($v6Dns.ServerAddresses -join ', ')"
            Set-DnsClientServerAddress -InterfaceIndex $newIndex `
                                       -ServerAddresses $v6Dns.ServerAddresses `
                                       -ErrorAction Stop
        }
    }

    # ── Apply DNS suffix and search domains ─────────────────────────────────

    if ($oldDnsClient) {
        $suffixParams = @{ InterfaceIndex = $newIndex }
        $hasSuffix = $false

        # Connection-specific DNS suffix (primary suffix for this adapter)
        if ($oldDnsClient.ConnectionSpecificSuffix) {
            $suffixParams['ConnectionSpecificSuffix'] = $oldDnsClient.ConnectionSpecificSuffix
            Write-Host "  DNS suffix: $($oldDnsClient.ConnectionSpecificSuffix)"
            $hasSuffix = $true
        }

        # DNS suffix search list (search domains for this adapter)
        if ($oldDnsClient.ConnectionSpecificSuffixSearchList -and $oldDnsClient.ConnectionSpecificSuffixSearchList.Count -gt 0) {
            $suffixParams['ConnectionSpecificSuffixSearchList'] = $oldDnsClient.ConnectionSpecificSuffixSearchList
            Write-Host "  DNS search domains: $($oldDnsClient.ConnectionSpecificSuffixSearchList -join ', ')"
            $hasSuffix = $true
        }

        # Whether this adapter registers its suffix when registering in DNS
        if ($null -ne $oldDnsClient.UseSuffixWhenRegistering) {
            $suffixParams['UseSuffixWhenRegistering'] = $oldDnsClient.UseSuffixWhenRegistering
        }

        # Whether this adapter registers its address in DNS
        if ($null -ne $oldDnsClient.RegisterThisConnectionsAddress) {
            $suffixParams['RegisterThisConnectionsAddress'] = $oldDnsClient.RegisterThisConnectionsAddress
        }

        if ($hasSuffix) {
            Set-DnsClient @suffixParams -ErrorAction Stop
        }
    }

    # ── Validate before removing the old NIC ────────────────────────────────

    Start-Sleep -Seconds 2

    if (-not $skipV4 -and $v4Gateway) {
        $ping4 = Test-Connection -TargetName $v4Gateway.NextHop -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping4) {
            Write-Host "  IPv4 gateway $($v4Gateway.NextHop) reachable." -ForegroundColor Green
        } else {
            Write-Warning "  IPv4 gateway $($v4Gateway.NextHop) not responding."
        }
    }

    if (-not $skipV6 -and $v6Gateway) {
        $ping6 = Test-Connection -TargetName $v6Gateway.NextHop -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($ping6) {
            Write-Host "  IPv6 gateway $($v6Gateway.NextHop) reachable." -ForegroundColor Green
        } else {
            Write-Warning "  IPv6 gateway $($v6Gateway.NextHop) not responding."
        }
    }

    # ── Remove the old NIC from the system ──────────────────────────────────

    if ($RemoveOld) {
        $pnpDevice = Get-PnpDevice | Where-Object {
            $_.InstanceId -eq $oldNic.PnPDeviceID -and $_.Class -eq 'Net'
        }
        if ($pnpDevice) {
            Write-Host "  Removing '$($oldNic.Name)' ($($oldNic.InterfaceDescription))..."
            Disable-NetAdapter -InterfaceIndex $oldIndex -Confirm:$false
            & pnputil /remove-device $pnpDevice.InstanceId | Out-Null
            Write-Host "  Removed." -ForegroundColor Green
        } else {
            Write-Warning "  Could not find PnP device for '$($oldNic.Name)' — remove it manually from Device Manager."
        }
    }

    $moved++
}

if ($moved -eq 0) {
    Write-Host "`nNo matching adapter pairs found. Ensure the VirtIO NIC has the same MAC as the old NIC." -ForegroundColor Yellow
} else {
    Write-Host "`nDone. Moved config on $moved adapter(s)." -ForegroundColor Green
}
