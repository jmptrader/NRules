param (
	[hashtable] $component
)

properties {
	$version = $null
	$target_framework = "net-4.0"
	$configuration = "Release"
}

$base_dir  = resolve-path .
$tools_dir = "$base_dir\tools"

include $tools_dir\build\buildutils.ps1

task default -depends Build

task Init {
	Assert ($version -ne $null) 'Version should not be null'
	Assert ($component -ne $null) 'Component should not be null'
	
	Write-Host "Building $($component.name) version $version ($configuration)" -ForegroundColor Green
	
	$comp_name = $component.name
	$src_root = if ($component.ContainsKey('src_root')) { $component.src_root } else { 'src' }
	
	$script:binaries_dir = "$base_dir\binaries\$comp_name"
	$script:src_dir = "$base_dir\$src_root\$comp_name"
	$script:build_dir = "$base_dir\build"
	$script:out_dir =  "$build_dir\output\$comp_name"
	$script:merge_dir = "$build_dir\merge\$comp_name"
	$script:pkg_out_dir = "$build_dir\packages\$comp_name"
	$script:packages_dir = "$base_dir\packages"
	$script:help_dir = "$base_dir\help"
	$script:tools_restore_dir = "$tools_dir\packages"
	
	$script:nuget_exec = "$tools_dir\.nuget\nuget.exe"
	$script:zip_exec = "$tools_restore_dir\7-Zip.CommandLine.9.20.0\tools\7za.exe"
	$script:ilmerge_exec = "$tools_restore_dir\ilmerge.2.14.1203\content\ilmerge.exe"
	$script:nunit_exec = "$tools_restore_dir\NUnit.Runners.2.6.3\tools\nunit-console.exe"
	
	if ($target_framework -eq "net-4.0") {
		$framework_root = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\.NETFramework\' 'InstallRoot' 
		$framework_root = $framework_root + "v4.0.30319"
		$script:msbuild_exec = $framework_root + "\msbuild.exe"
		$script:ilmerge_target_framework  = "/targetplatform:v4," + $framework_root
	}
}

task Clean -depends Init {
	Delete-Directory $out_dir
	Delete-Directory $merge_dir
	Delete-Directory $pkg_out_dir
	Delete-Directory $binaries_dir
}

task SetVersion {
	Write-Host Build Version: $version
	Update-AssemblyVersion $version
}

task ResetVersion {
	Reset-AssemblyVersion
}

task RestoreTools { 
	exec { &$script:nuget_exec restore $tools_dir -NonInteractive }
}

task RestoreDependencies { 
	exec { &$script:nuget_exec restore $src_dir -NonInteractive }
}

task Compile -depends Init, Clean, SetVersion, RestoreTools, RestoreDependencies { 
	Create-Directory $build_dir
	Create-Directory $out_dir
	
	$solution_file = "$src_dir\$($component.name).sln"
	$output = "$out_dir\"
	exec { &$script:msbuild_exec $solution_file /p:OutDir=$output /p:Configuration=$configuration /v:m /nologo }
}

task Test -depends Compile -precondition { return $component.ContainsKey('test') } {
	$test_files = @()
	$test_files += Get-ChildItem "$out_dir\*.*" -Include $component.test.include -Exclude $component.test.exclude
	$test_out_file = "$build_dir\TestResult_$($component.name).xml"
	exec { &$script:nunit_exec $test_files /nologo /framework:$target_framework /config:$configuration /xml:$test_out_file }
	
	if (Test-Path Env:CI) {
		Write-Host "Uploading to CI - $test_out_file"
		$wc = New-Object 'System.Net.WebClient'
		$wc.UploadFile("https://ci.appveyor.com/api/testresults/nunit/$($Env:APPVEYOR_JOB_ID)", (Resolve-Path $test_out_file))
	}
}

task Merge -depends Compile -precondition { return $component.ContainsKey('merge') } {
	Create-Directory $merge_dir
	
	$assemblies = @()
	$assemblies += Get-ChildItem "$out_dir\*.*" -Include $component.merge.include -Exclude $component.merge.exclude
	
	$attribute_file = "$out_dir\$($component.merge.attr_file)"
	
	$keyfile = "$base_dir\..\SigningKey.snk"
	if (-not (Test-Path $keyfile) ) {
		Write-Host "Key file for assembly signing does not exist. Signing with a development key." -ForegroundColor Yellow
		$keyfile = "$base_dir\DevSigningKey.snk"
	}
	
	$output = "$merge_dir\$($component.merge.out_file)"
	exec { &$script:ilmerge_exec /out:$output /log /keyfile:$keyfile $script:ilmerge_target_framework $assemblies /xmldocs /attr:$attribute_file }
}

task Build -depends Compile, Test, Merge, ResetVersion -precondition { return -not $component.ContainsKey('nobuild') } { 
	Create-Directory $binaries_dir
	
	if ($component.ContainsKey('merge') -and $component.bin.merge_include) {
		Get-ChildItem "$merge_dir\**" -Include $component.bin.merge_include -Exclude $component.bin.merge_exclude | Copy-Item -Destination $binaries_dir -Force
	}
	if ($component.ContainsKey('bin') -and $component.bin.out_include) {
		Get-ChildItem "$out_dir\**" -Include $component.bin.out_include -Exclude $component.bin.out_exclude | Copy-Item -Destination $binaries_dir -Force
	}
}

task PackageNuGet -depends Build -precondition { return $component.ContainsKey('package') -and $component.package.ContainsKey('nuget') } {
	$nuget = $component.package.nuget
	
	Create-Directory $pkg_out_dir
	Create-Directory $pkg_out_dir\$($nuget.id)\lib\net40
	
	Copy-Item $packages_dir\$($nuget.id).dll.nuspec $pkg_out_dir\$($nuget.id)\$($nuget.id).nuspec -Force
	Get-ChildItem "$binaries_dir\**" -Include $nuget.include -Exclude $nuget.exclude | Copy-Item -Destination $pkg_out_dir\$($nuget.id)\lib\net40 -Force

	# Set the package version
	$package = "$pkg_out_dir\$($nuget.id)\$($nuget.id).nuspec"
	$nuspec = [xml](Get-Content $package)
	$nuspec.package.metadata.version = $version
	$nuspec | Select-Xml '//dependency' |% {
		$_.Node.Version = $_.Node.Version -replace '\$version\$', "$version"
	}
	$nuspec.Save($package);
	exec { &$script:nuget_exec pack $package -OutputDirectory $pkg_out_dir }
}

task PackageZip -depends Build -precondition { $component.ContainsKey('package') -and $component.package.ContainsKey('zip') } {
	$zip = $component.package.zip
	Create-Directory $pkg_out_dir
	$file = "$pkg_out_dir\$($zip.name)"
	Delete-File $file
	exec { &$script:zip_exec a -tzip $file $binaries_dir }
}

task Package -depends Build, PackageNuGet, PackageZip {
}

task PublishNuGet -precondition { return $component.ContainsKey('package') -and $component.package.ContainsKey('nuget') } {
	$nuget = $component.package.nuget
	# Upload packages
	$accessKeyFile = "$base_dir\..\Nuget-Access-Key.txt"
	if ( (Test-Path $accessKeyFile) ) {
		$accessKey = Get-Content $accessKeyFile
		$accessKey = $accessKey.Trim()
		
		# Push to nuget repository
		exec { &$script:nuget_exec push "$pkg_out_dir\$($nuget.id).$version.nupkg" $accessKey }
	} else {
		Write-Host "Nuget-Access-Key.txt does not exist. Cannot publish the nuget package." -ForegroundColor Yellow
	}
}

task Publish -depends Package, PublishNuGet {
}

task Help -depends Init, Build -precondition { return $component.ContainsKey('help') } {
	Assert (Test-Path Env:\SHFBROOT) 'Sandcastle root environment variable SHFBROOT is not set'
	
	Create-Directory $build_dir
	
	$help_proj_file = "$help_dir\$($component.help)"
	exec { &$script:msbuild_exec $help_proj_file /v:m /nologo }
}
