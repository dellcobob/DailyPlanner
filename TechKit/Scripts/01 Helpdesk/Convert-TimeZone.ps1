# @Name:        Time Zone Converter
# @Description: Converts a time (or now) between time zones, for scheduling with users and vendors in other regions. Accepts partial zone names like "Pacific" or "Tokyo".
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        time zone, utc, convert, schedule, utility

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Date/time to convert, for example 2026-12-01 14:30 or 9am. Empty = now.')]
    [string]$Time = '',

    [Parameter(HelpMessage = 'Zone the time is in: Local, UTC, or part of a zone name')]
    [string]$From = 'Local',

    [Parameter(HelpMessage = 'Zones to show, one per line')]
    [string[]]$To = @('UTC', 'Eastern Standard Time', 'Central Standard Time', 'Pacific Standard Time', 'GMT Standard Time', 'Central Europe Standard Time', 'India Standard Time', 'AUS Eastern Standard Time'),

    [Parameter(HelpMessage = 'List every time zone name on this PC')]
    [switch]$ListZones
)

$all = [TimeZoneInfo]::GetSystemTimeZones()
if ($ListZones) {
    $all | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.DisplayName; Offset = $_.BaseUtcOffset.ToString() } }
    return
}

function Find-Zone {
    param([string]$Name)
    if ($Name -eq 'Local') { return [TimeZoneInfo]::Local }
    if ($Name -eq 'UTC') { return [TimeZoneInfo]::Utc }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Name) } catch { }
    $m = @($all | Where-Object { $_.Id -like "*$Name*" -or $_.DisplayName -like "*$Name*" -or $_.StandardName -like "*$Name*" })
    if ($m.Count -ge 1) { return $m[0] }
    throw "No time zone matches '$Name'. Tick ListZones to see the names."
}

$fromZone = Find-Zone $From
if ($Time) {
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Time, [ref]$parsed)) { throw "Could not read '$Time' as a date or time." }
    $source = [datetime]::SpecifyKind($parsed, 'Unspecified')
    $utc = [TimeZoneInfo]::ConvertTimeToUtc($source, $fromZone)
} else {
    $utc = [datetime]::UtcNow
}

Write-Host ("{0} in {1}" -f [TimeZoneInfo]::ConvertTimeFromUtc($utc, $fromZone).ToString('ddd yyyy-MM-dd HH:mm'), $fromZone.DisplayName) -ForegroundColor Cyan
foreach ($z in $To) {
    try {
        $tz = Find-Zone $z
        $t = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
        $off = $tz.GetUtcOffset($t)
        [pscustomobject]@{
            Zone     = $tz.Id
            Time     = $t.ToString('ddd yyyy-MM-dd HH:mm')
            UtcShift = ('{0}{1:hh\:mm}' -f $(if ($off -lt [TimeSpan]::Zero) { '-' } else { '+' }), $off)
            Daylight = $tz.IsDaylightSavingTime($t)
            WorkHours = $(if ($t.Hour -ge 8 -and $t.Hour -lt 18 -and $t.DayOfWeek -ne 'Saturday' -and $t.DayOfWeek -ne 'Sunday') { 'Yes' } else { 'No' })
        }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}
