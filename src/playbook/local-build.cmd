<# : batch portion
@echo off & powershell -nop Get-Content """%~f0""" -Raw ^| iex & exit /b
: end batch / begin PowerShell #>

# name of resulting apbx
$fileName = "Atlas Test"

# if the script should delete any playbook that already exists with the same name or not
# if not, it will make something like "Atlas Test (1).apbx"
$replaceOldPlaybook = $true

# choose to get Atlas dependencies or not to speed up installation
$removeDependencies = $false
# choose not to modify certain aspects from playbook.conf
$removeRequirements = $false
$removeBuildRequirement = $true
# not recommended to disable as it will show malicious
$removeProductCode = $true

# ------ #
# script #
# ------ #

$apbxFileName = "$fileName.apbx"
$apbxPath = "$PWD\$fileName.apbx"

if (!(Test-Path -Path "playbook.conf")) {
	Write-Host "playbook.conf file not found in the current directory." -ForegroundColor Red
	Start-Sleep 2
	exit 1
}

# check if old files are in use
if (($replaceOldPlaybook) -and (Test-Path -Path $apbxFileName)) {
	try {
		$stream = [System.IO.File]::Open($apbxFileName, 'Open', 'Read', 'Write')
		$stream.Close()
	} catch {
		Write-Host "The current playbook in the folder ($apbxFileName) is in use, and it can't be deleted to be replaced." -ForegroundColor Red
		Write-Host 'Either configure "$replaceOldPlaybook" in the script configuration or close the application its in use with.' -ForegroundColor Red
		Start-Sleep 4
		exit 1
	}
	Remove-Item -Path $apbxFileName -Force -EA 0
} else {
	if (Test-Path -Path $apbxFileName) {
		$num = 1
		while(Test-Path -Path "$fileName ($num).apbx") {$num++}
		$apbxFileName = "$PWD\$fileName ($num).apbx"
	}
}

$zipFileName = Join-Path -Path $PWD -ChildPath $([System.IO.Path]::ChangeExtension($apbxFileName, "zip"))

# remove old temp files
Remove-Item -Path $zipFileName -Force -EA 0
if (!($?) -and (Test-Path -Path "$zipFileName")) {
	Write-Host "Failed to delete temporary '$zipFileName' file!" -ForegroundColor Red
	Start-Sleep 2
	exit 1
}

# make temp directories
$rootTemp = Join-Path -Path $env:temp -ChildPath $([System.IO.Path]::GetRandomFileName())
New-Item $rootTemp -ItemType Directory -Force | Out-Null
if (!(Test-Path -Path "$rootTemp")) {
	Write-Host "Failed to create temporary directory!" -ForegroundColor Red
	Start-Sleep 2
	exit 1
}
$configDir = "$rootTemp\playbook\Configuration\atlas"
New-Item $configDir -ItemType Directory -Force | Out-Null

try {
	$tempPlaybookConf = "$rootTemp\playbook\playbook.conf"
	$ymlPath = "Configuration\atlas\start.yml"
	$tempStartYML = "$rootTemp\playbook\$ymlPath"

	# remove entries in playbook config that make it awkward for testing
	$patterns = @()
	# 0.6.5 has a bug where it will crash without the 'Requirements' field, but all of the requirements are removed
	# "<Requirements>" and # "</Requirements>"
	if ($removeRequirements) {$patterns += "<Requirement>"}
	if ($removeBuildRequirement) {$patterns += "<string>", "</SupportedBuilds>", "<SupportedBuilds>"}
	if ($removeProductCode) {$patterns += "<ProductCode>"}

	$newContent = Get-Content "playbook.conf" | Where-Object { $_ -notmatch ($patterns -join '|') }
	$newContent | Set-Content "$tempPlaybookConf" -Force

	if ($removeDependencies) {
		$startYML = "$PWD\$ymlPath"
		if (Test-Path $startYML -PathType Leaf) {
			Copy-Item -Path $startYML -Destination $tempStartYML -Force

			$content = Get-Content -Path $tempStartYML -Raw

			$startMarker = "  ################ NO LOCAL BUILD ################"
			$endMarker = "  ################ END NO LOCAL BUILD ################"

			$startIndex = $content.IndexOf($startMarker)
			$endIndex = $content.IndexOf($endMarker)

			if ($startIndex -ge 0 -and $endIndex -ge 0) {
				$newContent = $content.Substring(0, $startIndex) + $content.Substring($endIndex + $endMarker.Length)
				Set-Content -Path $tempStartYML -Value $newContent
			}
		}
	}

	$excludeFiles = @(
		"local-build.cmd",
		"playbook.conf",
		"*.apbx"
	); if (Test-Path $tempStartYML) { $excludeFiles += "start.yml" }

	# make playbook, 7z is faster
	$filteredItems = @()
	if (Get-Command '7z.exe' -EA SilentlyContinue) {
		$7zPath = '7z.exe'
	} elseif (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") {
		$7zPath = "$env:ProgramFiles\7-Zip\7z.exe"
	}

	if ($7zPath) {
		(Get-ChildItem -Recurse -File | Where-Object { $excludeFiles -notcontains $_.Name }).FullName `
		| Resolve-Path -Relative | ForEach-Object {$_.Substring(2)} | Out-File "$rootTemp\7zFiles.txt" -Encoding utf8

		& $7zPath a -spf -y -mx1 -tzip "$apbxPath" `@"$rootTemp\7zFiles.txt" | Out-Null
		# add edited files
		Push-Location "$rootTemp\playbook"
		& $7zPath u "$apbxPath" * | Out-Null
		Pop-Location
	} else {
		$filteredItems += (Get-ChildItem | Where-Object { $excludeFiles -notcontains $_.Name }).FullName + "$tempPlaybookConf"
		if (Test-Path $tempStartYML) { $filteredItems = $filteredItems + "$tempStartYML" }

		Compress-Archive -Path $filteredItems -DestinationPath $zipFileName
		Rename-Item -Path $zipFileName -NewName $apbxFileName
	}

	Write-Host "Completed." -ForegroundColor Green
} finally { 
	Remove-Item $rootTemp -Force -EA 0 -Recurse | Out-Null
}