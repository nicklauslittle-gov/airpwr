. $PSScriptRoot\registry.ps1
. $PSScriptRoot\config.ps1
. $PSScriptRoot\progress.ps1
. $PSScriptRoot\log.ps1
. $PSScriptRoot\db.ps1

function AsRemotePackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$RegistryTag
	)
	if ($RegistryTag -match '(.*)-([0-9].+)') {
		return @{
			Package = $Matches[1]
			Tag = $Matches[2] | AsTagHashtable
		}
	}
	throw "failed to parse registry tag: $RegistryTag"
}

function AsTagHashtable {
	param (
		[Parameter(ValueFromPipeline)]
		[string]$Tag
	)
	if ($Tag -in 'latest', '', $null) {
		return @{ Latest = $true }
	}
	if ($Tag -match '^([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:(?:\+|_)([0-9]+))?$') {
		return @{
			Major = $Matches[1]
			Minor = $Matches[2]
			Patch = $Matches[3]
			Build = $Matches[4]
		}
	}
	throw "failed to parse tag: $Tag"
}

function AsTagString {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[collections.Hashtable]$Tag
	)
	if ($true -eq $Tag.Latest) {
		"latest"
	} else {
		$s = "$($Tag.Major)"
		if ($Tag.Minor) {
			$s += ".$($Tag.Minor)"
		}
		if ($Tag.Patch) {
			$s += ".$($Tag.Patch)"
		}
		if ($Tag.Build) {
			$s += "+$($Tag.Build)"
		}
		$s
	}
}

function GetRemotePackages {
	$remote = @{}
	foreach ($tag in (GetTagsList).Tags) {
		$pkg = $tag | AsRemotePackage
		$remote.$($pkg.Package) = $remote.$($pkg.Package) + @($pkg.Tag)
	}
	$remote
}

function GetRemoteTags {
	$remote = GetRemotePackages
	$o = New-Object PSObject
	foreach ($k in $remote.keys | Sort-Object) {
		$arr = @()
		foreach ($t in $remote.$k) {
			$arr += [Tag]::new(($t | AsTagString))
		}
		$o | Add-Member -MemberType NoteProperty -Name $k -Value ($arr | Sort-Object -Descending)
	}
	$o
}

function AsPackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$Pkg
	)
	if ($Pkg -match '^([^:]+)(?::([^:]+))?(?:::?([^:]+))?$') {
		return @{
			Package = $Matches[1]
			Tag = $Matches[2] | AsTagHashtable
			Config = if ($Matches[3]) { $Matches[3] } else { 'default' }
		}
	}
	throw "failed to parse package: $Pkg"
}

function TryEachPackage {
	param (
		[Parameter(Mandatory, Position = 0)]
		[string[]]$Packages,
		[Parameter(Mandatory, Position = 1)]
		[scriptblock]$ScriptBlock,
		[string]$ActionDescription = 'process'
	)
	$results = @()
	$failures = @()
	foreach ($p in $Packages) {
		try {
			$results += $p | &$ScriptBlock
		} catch {
			Write-Error $_
			$failures += $p
		}
	}
	if ($failures.Count -gt 0) {
		throw "Failed to $ActionDescription packages: $($failures -join ', ')"
	}
	return $results
}

function ResolvePackageRefPath {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	return "$(GetAirpowerPath)\ref\$($Pkg.Package)$(if (-not $Pkg.Tag.Latest) { "-$($Pkg.Tag | AsTagString)" })"
}

function ResolveRemoteRef {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	$remote = GetRemoteTags
	if (-not $remote.$($Pkg.Package)) {
		throw "no such package: $($Pkg.Package)"
	}
	$want = $Pkg.Tag
	foreach ($got in $remote.$($Pkg.Package)) {
		$eq = $true
		if ($null -ne $want.Major) {
			$eq = $eq -and $want.Major -eq $got.Major
		}
		if ($null -ne $want.Minor) {
			$eq = $eq -and $want.Minor -eq $got.Minor
		}
		if ($null -ne $want.Patch) {
			$eq = $eq -and $want.Patch -eq $got.Patch
		}
		if ($null -ne $want.Build) {
			$eq = $eq -and $want.Build -eq $got.Build
		}
		if ($eq) {
			$Pkg.Version = $got.ToString()
			return "$($Pkg.Package)-$($Pkg.Version.Replace('+', '_'))"
		}
	}
	throw "no such $($Pkg.Package) tag: $($Pkg.Tag | AsTagString)"
}

function GetLocalPackages {
	$pkgs = @()
	$locks, $err = [Db]::TryLockAll('pkgdb')
	if ($err) {
		throw $err
	}
	try {
		foreach ($lock in $locks) {
			$tag = $lock.Key[2]
			$t = [Tag]::new($tag)
			$digest = if ($t.None) { $tag } else { $lock.Get() }
			$m = [Db]::Get(('metadatadb', $digest))
			$pkgs += [LocalPackage]@{
				Package = $lock.Key[1]
				Tag = $t
				Version = $m.Version
				Digest = $digest | AsDigest
				Size = $m.size | AsSize
				Updated = if ($m.updated) { [datetime]::Parse($m.updated) } else { }
				Orphaned = if ($m.orphaned) { [datetime]::Parse($m.orphaned) }
			}
			$lock.Unlock()
		}
	} finally {
		if ($locks) {
			$locks.Revert()
		}
	}
	if (-not $pkgs) {
		$pkgs = ,[LocalPackage]@{}
	}
	return $pkgs
}

function ResolvePackageDigest {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	if ($pkg.digest) {
		return $pkg.digest
	}
	$k = 'pkgdb', $Pkg.Package, ($Pkg.Tag | AsTagString)
	if ([Db]::ContainsKey($k)) {
		return [Db]::Get($k)
	}
}

function InstallPackage { # $locks, $status
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	$digest = $Pkg.Digest
	$name = $Pkg.Package
	$tag = $Pkg.Tag | AsTagString
	$locks = @()
	$mLock, $err = [Db]::TryLock(('metadatadb', $digest))
	if ($err) {
		throw "package '$digest' is in use by another airpower process"
	}
	$locks += $mLock
	$pLock, $err = [Db]::TryLock(('pkgdb', $name, $tag))
	if ($err) {
		$locks.Revert()
		throw "package '${name}:$tag' is in use by another airpower process"
	}
	$locks += $pLock
	$p = $pLock.Get()
	$m = $mLock.Get() | ConvertTo-HashTable
	$status = if ($null -eq $p) {
		if ($null -eq $m) {
			'new'
		} else {
			'tag'
		}
	} elseif ($digest -ne $p) {
		if ($null -eq $m) {
			'newer'
		} else {
			'ref'
		}
	} else {
		'uptodate'
	}
	$pLock.Put($digest)
	switch ($status) {
		{$_ -in 'new', 'newer'} {
			$mLock.Put(@{
				RefCount = 1
				Version = $Pkg.Version
				Size = $Pkg.Size
				Updated = [datetime]::UtcNow.ToString()
			})
		}
		{$_ -in 'newer', 'ref'} {
			$moLock, $err = [Db]::TryLock(('metadatadb', $p))
			if ($err) {
				$locks.Revert()
				throw "package '$p' is in use by another airpower process"
			}
			$locks += $moLock
			$mo = $moLock.Get() | ConvertTo-HashTable
			$mo.RefCount -= 1
			if ($mo.RefCount -eq 0) {
				$poLock, $err = [Db]::TryLock(('pkgdb', $name, $p))
				if ($err) {
					$locks.Revert()
					throw "package '$p' is in use by another airpower process"
				}
				$locks += $poLock
				$poLock.Put($null)
				$mo.Orphaned = [datetime]::UtcNow.ToString('u')
			}
			$moLock.Put($mo)
		}
		{$_ -in 'tag', 'ref'} {
			if ([Db]::ContainsKey(('pkgdb', $name, $digest))) {
				$dLock, $err = [Db]::TryLock(('pkgdb', $name, $digest))
				if ($err) {
					$locks.Revert()
					throw "package '$digest' is in use by another airpower process"
				}
				$locks += $dLock
				$dLock.Remove()
			}
			if ($m.RefCount -eq 0 -and $m.Orphaned) {
				$m.Remove('Orphaned')
			}
			$m.RefCount += 1
			$m.Updated = [datetime]::UtcNow.ToString()
			$mLock.Put($m)
		}
		'uptodate' {
			$m.Updated = [datetime]::UtcNow.ToString()
			$mLock.Put($m)
		}
	}
	return $locks, $status
}

function PullPackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg,
		[string]$Output
	)
	$remoteRef = $Pkg | ResolveRemoteRef
	$digest = $remoteRef | GetDigestForRef
	WriteHost "Pulling $($Pkg.Package):$($pkg.Tag | AsTagString)"
	WriteHost "Digest: $($digest)"
	$k = 'metadatadb', $digest
	if ([Db]::ContainsKey($k) -and ($m = [Db]::Get($k)) -and $m.Size -and -not $Output) {
		$size = $m.Size
	} else {
		$manifest = $remoteRef | GetManifest
		$manifest | DebugRateLimit
		$size = $manifest | GetSize
		if ($Output) {
			MakeDirIfNotExist "$Output\$remoteRef" | Out-Null
			$fs = [IO.File]::Open("$(Resolve-Path "$Output\$remoteRef")\manifest.json", [IO.FileMode]::Create)
			try {
				$task = $manifest.Content.CopyToAsync($fs)
				while (-not $task.IsCompleted) {
					Start-Sleep -Milliseconds 125
				}
			} finally {
				$fs.Close()
			}
			$manifest | SavePackage -Output "$Output\$remoteRef"
			return 'new'
		}
	}
	$Pkg.Digest = $digest
	$Pkg.Size = $size
	$locks, $status = $Pkg | InstallPackage
	try {
		$ref = "$($Pkg.Package):$($Pkg.Tag | AsTagString)"
		if ($status -eq 'uptodate') {
			WriteHost "Status: Package is up to date for $ref"
		} else {
			if ($status -in 'new', 'newer') {
				$manifest | SavePackage
			}
			$refpath = $Pkg | ResolvePackageRefPath
			MakeDirIfNotExist (Split-Path $refpath) | Out-Null
			if (Test-Path -Path $refpath -PathType Container) {
				[IO.Directory]::Delete($refpath)
			}
			New-Item $refpath -ItemType Junction -Target ($Pkg.Digest | ResolvePackagePath) | Out-Null
			WriteHost "Status: Downloaded newer package for $ref"
		}
		$locks.Unlock()
	} finally {
		if ($locks) {
			$locks.Revert()
		}
	}
	return $status
}

function SavePackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Net.Http.HttpResponseMessage]$Resp,
		[String]$Output
	)
	[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
	SetCursorVisible $false
	try {
		$layers = $Resp | GetPackageLayers
		$digest = $Resp | GetDigest
		$temp = @()
		foreach ($layer in $layers) {
			try {
				if ($Output) {
					$layer.Digest | SaveBlob -Output $Output
				} else {
					$temp += $layer.Digest | SaveBlob | ExtractTarGz -Digest $digest
				}
				"$($layer.Digest.Substring('sha256:'.Length).Substring(0, 12)): Pull complete" + ' ' * 60 | WriteConsole
			} finally {
				WriteConsole "`n"
			}
		}
		foreach ($tmp in $temp) {
			[IO.File]::Delete($tmp)
		}
	} finally {
		SetCursorVisible $true
	}
}

function UninstallPackage { # $locks, $digest, $err
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	$name = $Pkg.Package
	$tag = $Pkg.Tag | AsTagString
	$k = 'pkgdb', $name, $tag
	$locks = @()
	if (-not [Db]::ContainsKey($k)) {
		return $null, $null, "package '${name}:$tag' not installed"
	}
	$pLock, $err = [Db]::TryLock($k)
	if ($err) {
		return $null, $null, "package '${name}:$tag' is in use by another airpower process"
	}
	$locks += $pLock
	$p = $pLock.Get()
	$pLock.Remove()
	$mLock, $err = [Db]::TryLock(('metadatadb', $p))
	if ($err) {
		$locks.Revert()
		$null, $null, "package '$p' is in use by another airpower process"
	}
	$locks += $mLock
	$m = $mLock.Get()
	if ($m.refcount -gt 0) {
		$m.refcount -= 1
	}
	if ($m.refcount -eq 0) {
		$mLock.Remove()
		$digest = $p
	} else {
		$mLock.Put($m)
		$digest = $null
	}
	return $locks, $digest, $null
}

function DeleteDirectory {
	param (
		[string]$Dir
	)
	$name = [IO.Path]::GetRandomFileName()
	$tempDir = "$(GetPwrTempPath)\$name"
	[IO.Directory]::CreateDirectory($tempDir) | Out-Null
	try {
		Robocopy.exe $tempDir $Dir /MIR /PURGE | Out-Null
		[IO.Directory]::Delete($Dir)
	} finally {
		[IO.Directory]::Delete($tempDir)
	}
}

function RemovePackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[Collections.Hashtable]$Pkg
	)
	$locks, $digest, $err = $Pkg | UninstallPackage
	if ($null -ne $err) {
		throw $err
	}
	try {
		WriteHost "Untagged: $($Pkg.Package):$($pkg.Tag | AsTagString)"
		if ($null -ne $digest) {
			$content = $digest | ResolvePackagePath
			if (Test-Path $content -PathType Container) {
				DeleteDirectory $content
			}
			WriteHost "Deleted: $digest"
		}
		$refpath = $Pkg | ResolvePackageRefPath
		if (Test-Path -Path $refpath -PathType Container) {
			[IO.Directory]::Delete($refpath)
		}
		$locks.Unlock()
	} finally {
		if ($locks) {
			$locks.Revert()
		}
	}
}

function UninstallOrphanedPackages {
	param (
		[timespan]$Span
	)
	$now = [datetime]::UtcNow
	$locks = @()
	$metadata = @()
	$ls, $err = [Db]::TryLockAll('metadatadb')
	if ($err) {
		throw $err
	}
	foreach ($lock in $ls) {
		$m = $lock.Get() | ConvertTo-HashTable
		$orphaned = if ($m.orphaned) { $now - [datetime]::Parse($m.orphaned) }
		if ($m.refcount -eq 0 -and $orphaned -ge $Span) {
			$locks += $lock
			$m.digest = $lock.Key[1]
			$metadata += $m
			$lock.Remove()
		} else {
			$lock.Unlock()
		}
	}
	$ls, $err = [Db]::TryLockAll('pkgdb')
	if ($err) {
		if ($locks) {
			$locks.Revert()
		}
		throw $err
	}
	foreach ($lock in $ls) {
		if ($lock.Key[2].StartsWith('sha256:') -and $lock.Key[2] -in $metadata.digest) {
			$locks += $lock
			$lock.Remove()
		} else {
			$lock.Unlock()
		}
	}
	return $locks, $metadata
}

function PrunePackages {
	param (
		[switch]$Auto
	)
	$autoprune = (GetAirpowerAutoprune)
	if ($Auto -and -not $autoprune) {
		return
	}
	$span = if ($Auto) { [timespan]::Parse($autoprune) } else { [timespan]::Zero }
	$locks, $pruned = UninstallOrphanedPackages $span
	try {
		$bytes = 0
		foreach ($i in $pruned) {
			$content = $i.Digest | ResolvePackagePath
			WriteHost "Deleted: $($i.Digest)"
			$stats = Get-ChildItem $content -Recurse | Measure-Object -Sum Length
			$bytes += $stats.Sum
			if (Test-Path $content -PathType Container) {
				DeleteDirectory $content
			}
		}
		if ($pruned) {
			WriteHost "Total reclaimed space: $($bytes | AsByteString)"
			$locks.Unlock()
		}
	} finally {
		if ($locks) {
			$locks.Revert()
		}
	}
}

function GetOutofdatePackages {
	param (
		[timespan]$Span
	)
	$now = [datetime]::UtcNow
	$locks, $err = [Db]::TryLockAll('pkgdb')
	if ($err) {
		throw $err
	}
	$pkgs = @()
	try {
		foreach ($lock in $locks) {
			$tag = $lock.Key[2]
			if (-not $tag.StartsWith('sha256:')) {
				$mlock, $err = [Db]::TryLock(('metadatadb', $lock.Get()))
				if ($err) {
					throw $err
				}
				$m = $mlock.Get() | ConvertTo-HashTable
				$since = if ($m.updated) { $now - [datetime]::Parse($m.updated) } else { [timespan]::MaxValue }
				if ($since -ge $Span) {
					$pkgs += "$($lock.Key[1]):$($lock.Key[2])"
				}
				$mlock.Revert()
			}
			$lock.Revert()
		}
	} finally {
		if ($locks) {
			$locks.Revert()
		}
	}
	return $pkgs
}

function UpdatePackages {
	param (
		[switch]$Auto,
		[string[]]$Packages
	)
	$autoupdate = (GetAirpowerAutoupdate)
	if ($Auto -and -not $autoupdate) {
		return
	}
	$span = if ($Auto) { [timespan]::Parse($autoupdate) } else { [timespan]::MinValue }
	$pkgs = GetOutofdatePackages $span
	if ($Auto -and -not $pkgs) {
		return
	}
	$updated = 0
	$skipped = 0
	$formal_pkgs = if ($Packages) { $Packages | AsPackage | ForEach-Object { "$($_.Package):$($_.Tag | AsTagString)" } }
	foreach ($pkg in $pkgs) {
		if ($Auto -and $pkg -notin $formal_pkgs) {
			++$skipped
			continue
		}
		try {
			$status = $pkg | AsPackage | PullPackage
			if ($status -ne 'uptodate') {
				++$updated
			}
		} catch {
			if (-not $err) {
				$err = $_
			}
		}
	}
	if ($err) {
		throw $err
	}
	WriteHost "Updated $updated package$(if ($updated -ne 1) { 's' })$(if ($skipped -ne 0) { " (Run update command to check $skipped skipped package$(if ($skipped -ne 1) { 's' })" }))"
}

class Digest {
	[string]$Sha256

	Digest([string]$sha256) {
		$this.Sha256 = $sha256
	}

	[string] ToString() {
		return "$($this.Sha256.Substring('sha256:'.Length).Substring(0, 12))"
	}
}

function AsDigest {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$Digest
	)
	return [Digest]::new($Digest)
}

class Tag : IComparable {
	[object]$Major
	[object]$Minor
	[object]$Patch
	[object]$Build
	hidden [bool]$None
	hidden [bool]$Latest

	Tag([string]$tag) {
		if ($tag -eq '<none>' -or $tag.StartsWith('sha256:')) {
			$this.None = $true
			return
		}
		if ($tag -in 'latest', '') {
			$this.Latest = $true
			return
		}
		if ($tag -match '^([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:(?:\+|_)([0-9]+))?$') {
			$this.Major = $Matches[1]
			$this.Minor = $Matches[2]
			$this.Patch = $Matches[3]
			$this.Build = $Matches[4]
			return
		}
		throw "failed to parse tag: $tag"
	}

	[int] CompareTo([object]$Obj) {
		if ($Obj -isnot $this.GetType()) {
			throw "cannot compare types $($Obj.GetType()) and $($this.GetType())"
		}
		if ($this.Latest -or $Obj.Latest) {
			return $this.Latest - $Obj.Latest
		}
		if ($this.None -or $Obj.None) {
			return $Obj.None - $this.None
		}
		if ($this.Major -ne $Obj.Major) {
			return $this.Major - $Obj.Major
		} elseif ($this.Minor -ne $Obj.Minor) {
			return $this.Minor - $Obj.Minor
		} elseif ($this.Patch -ne $Obj.Patch) {
			return $this.Patch - $Obj.Patch
		} else {
			return $this.Build - $Obj.Build
		}
	}

	[string] ToString() {
		if ($this.None) {
			return ''
		}
		if ($null -eq $this.Major) {
			return 'latest'
		}
		$s = "$($this.Major)"
		if ($this.Minor) {
			$s += ".$($this.Minor)"
		}
		if ($this.Patch) {
			$s += ".$($this.Patch)"
		}
		if ($this.Build) {
			$s += "+$($this.Build)"
		}
		return $s
	}
}

function ResolvePackage {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[string]$Ref
	)
	if ($Ref.StartsWith('file:///')) {
		$i = $ref.IndexOf('<')
		$cfg = if ($i -eq -1 -and $ref.Length -gt $i + 1) { 'default' } else { $ref.Substring($i+1).Trim() }
		return @{
			Digest = $Ref
			Tag = @{}
			Config = $cfg
		}
	}
	$pkg = $Ref | AsPackage
	$digest = $pkg | ResolvePackageDigest
	$pullpolicy = (GetAirpowerPullPolicy)
	switch ($pullpolicy) {
		'IfNotPresent' {
			if (-not $digest) {
				$pkg | PullPackage | Out-Null
				$pkg.digest = $pkg | ResolvePackageDigest
			}
		}
		'Never' {
			if (-not $digest) {
				throw "cannot find package $($pkg.Package):$($pkg.Tag | AsTagString)"
			}
		}
		'Always' {
			$pkg | PullPackage | Out-Null
			$pkg.digest = $pkg | ResolvePackageDigest
		}
		default {
			throw "AirpowerPullPolicy '$pullpolicy' is not valid"
		}
	}
	return $pkg
}

class Size : IComparable {
	[long]$Bytes
	hidden [string]$ByteString

	Size([long]$Bytes, [string]$ByteString) {
		$this.Bytes = $Bytes
		$this.ByteString = $ByteString
	}

	[int] CompareTo([object]$Obj) {
		return $this.Bytes.CompareTo($Obj.Bytes)
	}

	[string] ToString() {
		return $this.ByteString
	}
}

function AsSize {
	param (
		[Parameter(Mandatory, ValueFromPipeline)]
		[long]$Bytes
	)
	return [Size]::new($Bytes, ($Bytes | AsByteString))
}

class LocalPackage {
	[object]$Package
	[Tag]$Tag
	[string]$Version
	[Digest]$Digest
	[Size]$Size
	[object]$Updated
	[object]$Orphaned
	# Signers
}
