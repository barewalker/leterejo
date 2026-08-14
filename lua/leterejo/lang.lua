-- Message catalogue.
--
-- English is the default. Set `lang = "ja"` in setup() to switch.
-- Unknown keys fall back to English, then to the key itself, so a missing
-- translation degrades instead of erroring.
local M = {}

local strings = {}

strings.en = {
  -- generic
  prefix = "leterejo: ",
  no_candidates = "No candidates",
  unknown_open_mode = "Unknown open mode: %s",

  -- errors from the CLI layer
  err_passphrase = "Passphrase cache expired. Run `pass show ...` in a terminal to unlock",
  err_dns = "Could not reach %s (name lookup failed). The connection may have dropped",
  err_json = "Could not parse JSON: %s",
  err_generic = "himalaya failed to run",
  err_notmuch = "notmuch failed to run",
  err_archive_only = "This message is only in the local archive, so its state cannot be changed (no IMAP UID)",

  -- envelope list
  loading = "Loading…",
  preparing = "Preparing connection…",
  count = "%d messages",
  readonly = "  [read-only]",
  page = "page %d",
  empty = "  (no messages)",
  no_subject = "(no subject)",
  no_name = "(unnamed)",
  filtered_by = "filtered by “%s”",
  search_hint = "%s to change, %s to clear",
  scope_server = "server search",
  scope_local = "from the latest %d",
  scope_index = "whole index",
  suspicious_needs_index = "is:suspicious needs an account that reads locally",
  searching = "Filtering… %s",

  -- continuous list
  count_of = "%s of %s",
  count_threads = "%s of %s conversations",
  loading_more = "  loading more…",
  end_of_list = "  (end of list)",

  -- column names
  col_date = "Date",
  col_from = "From",
  col_subject = "Subject",

  -- threads
  thread_loading = "Opening the conversation…",
  thread_single = "This row is a single message",
  no_threads_here = "This account lists messages, not conversations",

  -- key list
  help_title = "Keys",
  help_none = "Nothing is bound here",

  -- message view
  reading = "Loading… %s",
  attachments_head = "── %d attachment(s) ──",
  headers_folded = "  … %d more headers (%s to show)",
  headers_now_folded = "Headers folded",
  headers_now_shown = "Headers expanded",
  wrap_on = "Wrapping long lines",
  wrap_off = "Not wrapping; scroll sideways",
  no_message_shown = "No message is displayed",
  source_not_found = "The original message is not in the list",

  -- attachments
  no_attachments = "This message has no attachments",
  downloading = "Downloading %d attachment(s)…",
  saved_to = "Saved %d file(s) to %s",
  saved_one = "Saved: %s",
  nothing_saved = "No attachment could be saved",
  checking_attachments = "Checking attachments…",
  pick_attachment = "Attachment to open",
  opening = "Opening… (press q / Esc / Ctrl-C to quit)",
  no_open_command = "No command configured to open this",
  not_executable = "`%s` not found. Saved to: %s",
  launch_failed = "Failed to launch",
  exit_code = "Exit code %d",
  herdr_missing = "herdr not found",
  herdr_no_pane = "Could not create a pane: %s",
  herdr_no_id = "Could not read the new pane id",
  herdr_no_reply = "Could not parse herdr's response",
  herdr_run_failed = "Could not run in the pane: %s",
  tmux_outside = "Not running inside tmux",

  -- compose
  no_draft = "No draft in progress",
  to_empty = "To is empty",
  body_empty = "Body is empty",
  no_email_configured = "No email configured for account `%s`",
  sending = "Sending as %s…%s",
  sent = "Sent",
  bcc_note = " (Bcc: %s)",
  send_failed = "Could not send",
  discard_prompt = "Discard this draft?",
  discard_yes = "Discard",
  discard_no = "Keep writing",
  looking_up = "Looking up recipients…",
  reply_fallback = "Could not read the original recipients. Replying to the sender only",
  quote_headline = "On %s, %s wrote:",
  quote_headline_noname = "On %s, the sender wrote:",

  -- operations on mail
  readonly_refused = "Account `%s` is read-only; nothing was changed",
  marked_read = "Marked as read",
  marked_unread = "Marked as unread",
  marked_flagged = "Flagged",
  marked_unflagged = "Flag removed",
  no_mailbox_configured = "No %s mailbox is configured for account `%s`",
  kind_trash = "trash",
  kind_archive = "archive",
  kind_spam = "spam",
  already_there = "Already in %s",
  moving = "Moving to %s…",
  moved = "Moved to %s",
  trash_prompt = "Move to the trash: %s",
  trash_yes = "Move to the trash",
  trash_no = "Keep it",

  -- pickers
  pick_mailbox = "Mailbox",
  pick_move_target = "Move to",
  pick_account = "Account",
  search_prompt = "Filter: ",

  -- key hints (kept short; they share one line)
  hint_read = "open",
  hint_reply = "reply",
  hint_forward = "fwd",
  hint_compose = "new",
  hint_account = "account",
  hint_mailbox = "box",
  hint_search = "filter",
  hint_attachments = "attach",
  hint_seen = "seen",
  hint_flagged = "flag",
  hint_trash = "trash",
  hint_archive = "arch",
  hint_spam = "spam",
  hint_move = "move",
  hint_refresh = "reload",
  hint_next_page = "next",
  hint_prev_page = "prev",
  hint_close = "close",
  hint_headers = "headers",
  hint_back = "back",

  -- keymap descriptions
  desc_read = "Open message",
  desc_reply = "Reply",
  desc_reply_other = "Reply the other way",
  desc_forward = "Forward",
  desc_compose = "Write a new message",
  desc_account = "Switch account",
  desc_mailbox = "Switch mailbox",
  desc_search = "Filter",
  desc_clear_search = "Clear filter",
  desc_attachments = "Save and open attachments",
  desc_toggle_seen = "Mark read or unread",
  desc_toggle_flagged = "Add or remove the flag",
  desc_trash = "Move to the trash",
  desc_archive = "Archive",
  desc_spam = "Report as spam",
  desc_move = "Move to a mailbox",
  desc_refresh = "Reload",
  desc_next_page = "Next page",
  desc_prev_page = "Previous page",
  desc_expand = "Open the conversation",
  desc_collapse = "Close the conversation",
  desc_toggle_thread = "Open or close the conversation",
  desc_help = "List the keys",
  desc_close = "Close",
  desc_back = "Back to list",
  desc_toggle_headers = "Toggle headers",
  desc_toggle_wrap = "Wrap long lines, or not",
  desc_send = "Send",
  desc_discard = "Discard",
}

strings.ja = {
  prefix = "leterejo: ",
  no_candidates = "候補がありません",
  unknown_open_mode = "知らない開き方です: %s",

  err_passphrase = "パスフレーズのキャッシュが切れています。端末で `pass show ...` を実行して解錠してください",
  err_dns = "%s に接続できませんでした (名前を引けません)。回線が一時的に途切れた可能性があります",
  err_json = "JSON を解釈できませんでした: %s",
  err_generic = "himalaya の実行に失敗しました",
  err_notmuch = "notmuch の実行に失敗しました",
  err_archive_only = "この通は手元の書庫にしかないため、状態を変えられません (IMAP の UID がありません)",

  loading = "読み込み中…",
  preparing = "接続を準備しています…",
  count = "%d 件",
  readonly = "  [読み取り専用]",
  page = "%d ページ目",
  empty = "  (メールがありません)",
  no_subject = "(件名なし)",
  no_name = "(名前なし)",
  filtered_by = "「%s」で絞り込み",
  search_hint = "%s で変更、%s で解除",
  scope_server = "サーバ検索",
  scope_local = "直近 %d 通から",
  scope_index = "索引全体から",
  suspicious_needs_index = "is:suspicious は手元索引を読む口座でのみ使えます",
  searching = "絞り込んでいます… %s",

  count_of = "%s / %s 件",
  count_threads = "%s / %s 件のやり取り",
  loading_more = "  続きを読み込んでいます…",
  end_of_list = "  (ここまで)",

  col_date = "日付",
  col_from = "差出人",
  col_subject = "件名",

  thread_loading = "やり取りを開いています…",
  thread_single = "この行は 1 通だけです",
  no_threads_here = "このアカウントはやり取りではなく 1 通ずつの一覧です",

  help_title = "キー一覧",
  help_none = "ここに割り当てられたキーはありません",

  reading = "読み込み中… %s",
  attachments_head = "── 添付 %d 件 ──",
  headers_folded = "  … 他 %d 個のヘッダー (%s で表示)",
  headers_now_folded = "ヘッダーをたたみました",
  headers_now_shown = "ヘッダーをすべて表示",
  wrap_on = "長い行を折り返します",
  wrap_off = "折り返しません (横にスクロールしてください)",
  no_message_shown = "表示中のメールがありません",
  source_not_found = "元のメールが一覧に見つかりません",

  no_attachments = "このメールに添付はありません",
  downloading = "添付 %d 件を保存しています…",
  saved_to = "%d 件を %s に保存しました",
  saved_one = "保存しました: %s",
  nothing_saved = "保存できる添付がありませんでした",
  checking_attachments = "添付を確認しています…",
  pick_attachment = "開く添付",
  opening = "開いています… (終わるには q / Esc / Ctrl-C)",
  no_open_command = "開くための命令が設定されていません",
  not_executable = "`%s` が見つかりません。保存先: %s",
  launch_failed = "起動に失敗しました",
  exit_code = "終了コード %d",
  herdr_missing = "herdr が見つかりません",
  herdr_no_pane = "ペインを作れませんでした: %s",
  herdr_no_id = "ペインの id を取り出せませんでした",
  herdr_no_reply = "herdr の応答を解釈できませんでした",
  herdr_run_failed = "ペインで実行できませんでした: %s",
  tmux_outside = "tmux の中で動いていません",

  no_draft = "書きかけのメールがありません",
  to_empty = "宛先 (To) が空です",
  body_empty = "本文が空です",
  no_email_configured = "アカウント `%s` の email が設定されていません",
  sending = "%s から送信しています…%s",
  sent = "送信しました",
  bcc_note = " (Bcc: %s)",
  send_failed = "送信できませんでした",
  discard_prompt = "書きかけのメールを破棄しますか",
  discard_yes = "破棄する",
  discard_no = "書き続ける",
  looking_up = "宛先を調べています…",
  reply_fallback = "元の宛先を読めませんでした。差出人にだけ返します",
  quote_headline = "%s に %s さんは書きました:",
  quote_headline_noname = "%s に、次のように書かれていました:",

  readonly_refused = "アカウント `%s` は読み取り専用です。何も変えていません",
  marked_read = "既読にしました",
  marked_unread = "未読に戻しました",
  marked_flagged = "印を付けました",
  marked_unflagged = "印を外しました",
  no_mailbox_configured = "%s のメールボックスがアカウント `%s` に設定されていません",
  kind_trash = "ごみ箱",
  kind_archive = "保管",
  kind_spam = "迷惑メール",
  already_there = "すでに %s にあります",
  moving = "%s へ移しています…",
  moved = "%s へ移しました",
  trash_prompt = "ごみ箱へ移す: %s",
  trash_yes = "ごみ箱へ移す",
  trash_no = "やめる",

  pick_mailbox = "メールボックス",
  pick_move_target = "移す先",
  pick_account = "アカウント",
  search_prompt = "絞り込み: ",

  hint_read = "開く",
  hint_reply = "返信",
  hint_forward = "転送",
  hint_compose = "新規",
  hint_account = "アカウント",
  hint_mailbox = "箱",
  hint_search = "絞込",
  hint_attachments = "添付",
  hint_seen = "既読",
  hint_flagged = "印",
  hint_trash = "ごみ箱",
  hint_archive = "保管",
  hint_spam = "迷惑",
  hint_move = "移動",
  hint_refresh = "更新",
  hint_next_page = "次頁",
  hint_prev_page = "前頁",
  hint_close = "閉じる",
  hint_headers = "ヘッダー",
  hint_back = "戻る",

  desc_read = "メールを開く",
  desc_reply = "返信する",
  desc_reply_other = "もう一方のやり方で返信する",
  desc_forward = "転送する",
  desc_compose = "新しく書く",
  desc_account = "アカウントを切り替える",
  desc_mailbox = "メールボックスを切り替える",
  desc_search = "絞り込む",
  desc_clear_search = "絞り込みを解除する",
  desc_attachments = "添付を保存して開く",
  desc_toggle_seen = "既読・未読を切り替える",
  desc_toggle_flagged = "印を付け外しする",
  desc_trash = "ごみ箱へ移す",
  desc_archive = "保管する",
  desc_spam = "迷惑メールとして報告する",
  desc_move = "メールボックスへ移す",
  desc_refresh = "取り直す",
  desc_next_page = "次のページ",
  desc_prev_page = "前のページ",
  desc_expand = "やり取りを開く",
  desc_collapse = "やり取りを閉じる",
  desc_toggle_thread = "やり取りを開く・閉じる",
  desc_help = "キー一覧を出す",
  desc_close = "閉じる",
  desc_back = "一覧に戻る",
  desc_toggle_headers = "ヘッダーの表示を切り替える",
  desc_toggle_wrap = "長い行の折り返しを切り替える",
  desc_send = "送信する",
  desc_discard = "破棄する",
}

-- Look up a message, formatting it when arguments are given.
function M.t(key, ...)
  local lang = require("leterejo.config").options.lang or "en"
  local table_ = strings[lang] or strings.en
  local s = table_[key] or strings.en[key] or key

  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, s, ...)
    return ok and formatted or s
  end
  return s
end

-- Same, prefixed with the plugin name. Used for anything shown as an error.
function M.e(key, ...)
  return M.t("prefix") .. M.t(key, ...)
end

-- Expose the catalogue so users can add or override entries.
function M.extend(lang, entries)
  strings[lang] = vim.tbl_extend("force", strings[lang] or {}, entries or {})
end

return M
