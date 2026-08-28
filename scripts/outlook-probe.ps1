# What can be read and written on a Windows machine that runs Outlook?
#
# Everything this asks decides how mail at work can be reached from Neovim, so
# it is asked on the machine itself rather than guessed. Nothing is sent, moved
# or marked read: the only thing written is a draft, which is deleted again.
#
# From WSL:
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w ~/Projects/leterejo/scripts/outlook-probe.ps1)"
#
# If it stops and says nothing, a dialog is waiting on the Windows desktop:
# that is Outlook's programmatic access guard, and it is itself the answer to
# question 5.
#
# The report is JSON on stdout and prose on stderr, so a machine and a person
# can both read it:
#
#   ... -File probe.ps1 2>&1 >report.json | less

# PowerShell 5.1 writes the console encoding, which on a Japanese Windows is
# CP932; a UTF-8 reader on the other side of the pipe gets mojibake. Measured
# on a Japanese Windows 11: subjects came back unreadable until this line.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Say($text) { [Console]::Error.WriteLine($text) }
function Try-Get($block, $fallback = $null) {
  try { & $block } catch { $fallback }
}

$report = [ordered]@{}

# 1. Which Outlook, if any.
#
# The one that matters is classic Outlook: the new Outlook for Windows
# (an appx, Microsoft.OutlookForWindows) has no COM and no MAPI, and nothing
# below works against it.
$report.powershell = $PSVersionTable.PSVersion.ToString()
$report.windows = Try-Get { (Get-CimInstance Win32_OperatingSystem).Caption }
$report.outlook_com = Try-Get {
  (Get-ItemProperty 'HKLM:\SOFTWARE\Classes\Outlook.Application\CurVer').'(default)'
} 'not registered'
$report.outlook_exe = Try-Get {
  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE').'(default)'
}
$report.new_outlook = [bool](Try-Get { Get-AppxPackage Microsoft.OutlookForWindows })
$report.outlook_running = [bool](Try-Get { Get-Process OUTLOOK -ErrorAction SilentlyContinue })

Say "Outlook (COM)      : $($report.outlook_com)"
Say "new Outlook (appx) : $($report.new_outlook)"
Say "running now        : $($report.outlook_running)"

if ($report.outlook_com -eq 'not registered') {
  Say ''
  Say 'No classic Outlook: COM is out, and only the file route is left.'
  $report | ConvertTo-Json -Depth 6
  exit 0
}

# 2. Attach to the running Outlook, or start one.
#
# New-Object attaches to the instance the user already has open when there is
# one, which is what makes this route work at all: the store stays open in
# Outlook and nothing has to take the lock away from it.
$attached = Measure-Command { $ol = New-Object -ComObject Outlook.Application }
$ns = $ol.GetNamespace('MAPI')
$report.attach_ms = [int]$attached.TotalMilliseconds
Say "attach             : $($report.attach_ms) ms"

# 3. The stores, and the file each one is.
#
# A POP3 account keeps its mail in a .pst. That file is the thing to read when
# Outlook is closed, and its size is the number that decides whether copying it
# anywhere is sensible.
$stores = @()
foreach ($s in $ns.Stores) {
  $path = Try-Get { $s.FilePath }
  $stores += [ordered]@{
    name = Try-Get { $s.DisplayName }
    path = $path
    type = Try-Get { $s.ExchangeStoreType }   # 3 = not Exchange, i.e. a local file
    size_mb = if ($path -and (Test-Path $path)) { [int]((Get-Item $path).Length / 1MB) } else { $null }
  }
}
$report.stores = $stores
foreach ($s in $stores) { Say ("store              : {0}  {1} MB  {2}" -f $s.name, $s.size_mb, $s.path) }

# 4. How long a screenful of the inbox takes.
#
# A list is worth building this way only if it arrives in the time a list takes
# to read. Sorted by arrival, newest first, taking only the fields a list shows
# - the body is not touched here.
$inbox = $ns.GetDefaultFolder(6)
$report.inbox_count = Try-Get { $inbox.Items.Count }

$items = $inbox.Items
$items.Sort('[ReceivedTime]', $true)
$envelopes = @()
$listing = Measure-Command {
  $i = 0
  foreach ($m in $items) {
    $i++
    if ($i -gt 200) { break }
    $envelopes += [ordered]@{
      subject = Try-Get { $m.Subject }
      from    = Try-Get { $m.SenderName }
      date    = Try-Get { $m.ReceivedTime.ToString('yyyy-MM-dd HH:mm') }
      unread  = Try-Get { $m.UnRead }
      id      = Try-Get { $m.EntryID }
    }
  }
}
$report.listing_200_ms = [int]$listing.TotalMilliseconds
$report.listing_got = $envelopes.Count
Say "inbox              : $($report.inbox_count) items"
Say "200 envelopes      : $($report.listing_200_ms) ms"

# 5. Whether the body can be read without a dialog.
#
# The guard fires on the body, the addresses and on sending. If this prints a
# length, the route is open; if the script stopped before printing anything,
# look at the Windows desktop.
$first = Try-Get { $items.GetFirst() }
$report.body_chars = Try-Get { $first.Body.Length } -1
$report.body_html_chars = Try-Get { $first.HTMLBody.Length } -1
$report.sender_address = Try-Get { $first.SenderEmailAddress } 'blocked'
Say "body               : $($report.body_chars) chars (-1 = blocked)"
Say "sender address     : $($report.sender_address)"

# 6. Whether writing works, without writing anything that leaves.
#
# A draft is created, saved into Drafts, and deleted again. Nothing is sent.
# The deleted draft lands in Deleted Items, where Outlook puts everything.
$report.write = Try-Get {
  $draft = $ol.CreateItem(0)
  $draft.Subject = 'leterejo probe (delete me)'
  $draft.Body = 'Written by outlook-probe.ps1 and deleted immediately.'
  $draft.Save()
  $id = $draft.EntryID
  $draft.Delete()
  "ok ($id)"
} 'blocked'
Say "draft write        : $($report.write)"

# 7. What the file route would cost, if COM turns out to be barred.
#
# readpst converts a .pst to Maildir, which notmuch indexes and leterejo reads
# with no new code at all. Outlook holds the file open, so this reports whether
# it can be copied while Outlook runs - the answer decides whether the
# conversion has to wait until Outlook is closed.
$pst = ($stores | Where-Object { $_.path -like '*.pst' } | Select-Object -First 1)
if ($pst) {
  $report.pst_copyable_while_open = Try-Get {
    $tmp = Join-Path $env:TEMP 'leterejo-lock-test.bin'
    $in = [IO.File]::Open($pst.path, 'Open', 'Read', 'ReadWrite')
    $in.Close()
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $true
  } $false
  Say "pst readable now   : $($report.pst_copyable_while_open)"
}

$report | ConvertTo-Json -Depth 6
