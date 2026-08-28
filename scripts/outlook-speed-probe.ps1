# How fast can a list be built from Outlook, and by which road?
#
# The first probe answered whether the door is open. This one asks whether what
# is behind it is quick enough to put a list on, because a list that takes
# seconds is not a list. Nothing is written; nothing is marked read.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Users\...\outlook-speed-probe.ps1'
#
# Three roads are timed against the same inbox:
#
#   1. Items      one MailItem per message, one COM round trip per property.
#                 What the first probe measured, and the obvious way to write it.
#   2. GetTable   a table of columns, no MailItem built at all. Rows are pulled
#                 one at a time.
#   3. GetArray   the same table, handed over in one call rather than per row.
#
# Then a body, since a list is only half of reading; and a search, since the
# other half is finding. The totals across every folder are counted last, to
# say how much there is to reach in the first place.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
function Say($t) { [Console]::Error.WriteLine($t) }
function Try-Get($b, $f = $null) { try { & $b } catch { $f } }

$report = [ordered]@{}
$ol = Try-Get { New-Object -ComObject Outlook.Application }
if (-not $ol) { Say 'No classic Outlook here.'; '{}'; exit 0 }
$ns = $ol.GetNamespace('MAPI')
$inbox = $ns.GetDefaultFolder(6)
$report.inbox_count = $inbox.Items.Count
$N = 200

# 1. One object per message.
$items = $inbox.Items
$items.Sort('[ReceivedTime]', $true)
$report.items_ms = [int](Measure-Command {
  $i = 0
  foreach ($m in $items) {
    $i++; if ($i -gt $N) { break }
    $null = $m.Subject, $m.SenderName, $m.ReceivedTime, $m.UnRead, $m.EntryID
  }
}).TotalMilliseconds
Say "Items    $N rows : $($report.items_ms) ms"

# 2 and 3. A table of columns.
#
# Column names are tried in their friendly form first; if Outlook refuses them
# the DASL URNs are used, and which one worked is reported, because the backend
# has to know which names it may say.
function New-Table($folder, $names) {
  $t = $folder.GetTable()
  $t.Columns.RemoveAll()
  foreach ($n in $names) { $null = $t.Columns.Add($n) }
  # Sort takes a boolean in some versions and OlSortOrder in others; whichever
  # this one is, an unsorted table is still usable, so a refusal is not fatal.
  try { $t.Sort('ReceivedTime', $true) } catch { try { $t.Sort('ReceivedTime', 2) } catch { } }
  return $t
}

$friendly = @('Subject', 'SenderName', 'ReceivedTime', 'UnRead', 'EntryID')
$dasl = @(
  'urn:schemas:httpmail:subject',
  'urn:schemas:httpmail:fromname',
  'urn:schemas:httpmail:datereceived',
  'urn:schemas:httpmail:read',
  'EntryID'
)

$names = $friendly
$table = Try-Get { New-Table $inbox $friendly }
if (-not $table) {
  $names = $dasl
  $table = Try-Get { New-Table $inbox $dasl }
}
$report.column_names = if ($table) { if ($names -eq $friendly) { 'friendly' } else { 'dasl' } } else { 'neither' }
Say "columns          : $($report.column_names)"

if ($table) {
  # $script: because Measure-Command runs its block in a child scope, where a
  # bare += would build a copy and leave this one empty.
  $script:rows = @()
  $report.table_rows_ms = [int](Measure-Command {
    $i = 0
    while (-not $table.EndOfTable -and $i -lt $N) {
      $i++
      $row = $table.GetNextRow()
      $script:rows += , @($row[$names[0]], $row[$names[1]], $row[$names[2]], $row[$names[3]])
    }
  }).TotalMilliseconds
  $report.table_rows_got = $script:rows.Count
  Say "GetTable $N rows : $($report.table_rows_ms) ms"

  $table2 = Try-Get { New-Table $inbox $names }
  $report.table_array_ms = [int](Measure-Command { $arr = $table2.GetArray($N) }).TotalMilliseconds
  Say "GetArray $N rows : $($report.table_array_ms) ms"

  # The whole inbox in one go, which is what a first run would do.
  $table3 = Try-Get { New-Table $inbox $names }
  $report.table_all_ms = [int](Measure-Command { $all = $table3.GetArray($report.inbox_count) }).TotalMilliseconds
  Say "GetArray all     : $($report.table_all_ms) ms for $($report.inbox_count)"

  # What a subject actually looks like through the table, since a name that
  # returns nothing is worse than one that errors.
  $sample = Try-Get { (New-Table $inbox $names).GetArray(1) }
  $report.sample_row = Try-Get { @($sample[0, 0], $sample[0, 1], $sample[0, 2]) -join ' | ' } 'unreadable'
  Say "sample row       : $($report.sample_row)"
}

# 4. A body, five times, since the first one warms whatever caches exist.
$first = $items.GetFirst()
$body_ms = @()
for ($i = 0; $i -lt 5; $i++) {
  $body_ms += [int](Measure-Command { $null = $first.Body }).TotalMilliseconds
}
$report.body_ms = $body_ms
Say "body x5          : $($body_ms -join ', ') ms"

$report.html_ms = [int](Measure-Command { $null = $first.HTMLBody }).TotalMilliseconds
Say "html body        : $($report.html_ms) ms"

# 5. Finding something. Restrict with a text match only works where Windows
# Search has indexed the store; if it has not, this is the number that says so.
$q = "@SQL=" + '"' + 'urn:schemas:httpmail:subject' + '" LIKE ' + "'%report%'"
$report.restrict_like_ms = [int](Measure-Command {
  $found = Try-Get { $items.Restrict($q) }
  $report.restrict_like_hits = Try-Get { $found.Count } -1
}).TotalMilliseconds
Say "Restrict LIKE    : $($report.restrict_like_ms) ms, $($report.restrict_like_hits) hits"

$ci = "@SQL=" + '"' + 'urn:schemas:httpmail:textdescription' + '" ci_phrasematch ' + "'report'"
$report.restrict_fulltext_ms = [int](Measure-Command {
  $found2 = Try-Get { $items.Restrict($ci) }
  $report.restrict_fulltext_hits = Try-Get { $found2.Count } -1
}).TotalMilliseconds
Say "Restrict fulltext: $($report.restrict_fulltext_ms) ms, $($report.restrict_fulltext_hits) hits (-1 = not indexed)"

# 6. How much there is altogether, which decides what a first run costs.
$script:folders = @()
function Walk($f, $depth) {
  if ($depth -gt 4) { return }
  $script:folders += [ordered]@{ name = $f.Name; items = Try-Get { $f.Items.Count } -1 }
  foreach ($sub in $f.Folders) { Walk $sub ($depth + 1) }
}
foreach ($store in $ns.Folders) { Walk $store 0 }
$report.folders = $script:folders
$report.total_items = ($script:folders | Measure-Object -Property items -Sum).Sum
Say "folders          : $($script:folders.Count), $($report.total_items) items in all"

$report | ConvertTo-Json -Depth 6
