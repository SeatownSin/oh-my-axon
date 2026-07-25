@{
    # Information-level rules are advisory only. Notably PSAvoidUsingPositionalParameters
    # fires on `npx --no-install prettier --write $file`, treating a native
    # executable as if it were a cmdlet.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # An installer's entire job is to talk to the console. Write-Output
        # would put status lines on the pipeline, where Install-OmaFile's
        # caller would have to filter them out of real return values, and
        # Write-Information is silent unless the user opts in -- wrong for
        # an interactive installer. Write-Host is the correct cmdlet here.
        #
        # This is scoped by intent, not blanket: the hook scripts do not use
        # Write-Host at all. secret-scan.ps1 emits its decision on stdout via
        # Write-Output, which is right, because Axon parses it.
        'PSAvoidUsingWriteHost'
    )
}
