# leterejo.nvim

手元の [notmuch][] 索引を読み、状態の変更はタグで行い、送信は [himalaya][] に任せる Neovim のメールクライアント。メールの取得は [lieer][] が Gmail の API 越しに Maildir を同期して行う。

**一覧 50 件で 37 ミリ秒、本文は 10〜20 ミリ秒。** 読み取りの経路が一度も機外に出ないため。

日本語を主要な対象として扱う。索引は日本語が引けるように作り、件名と添付名は notmuch に任せず自前で復号し、本文が HTML しかないメール (ここでは半分以上) は表示前に整形する。

English: [README.md](README.md)

## 誰のための道具か

**Gmail を使っていて、同期の道具を自分で回す気がある人。** IMAP の経路は無い。メールはこの機械にあるか、無いなら読めない。すでに notmuch を使っているなら「画面を足す」感覚で入る。そうでないなら、土台の準備に 30 分は見てほしい。決める前に [できないこと](#できないこと) にも目を通すこと。

```
       Gmail
         │  lieer (gmi sync — API で双方向)
         ↓
   ~/Mail/<アカウント>-lieer/mail/     アカウントごとに 1 つの置き場
         │
         ↓  notmuch。索引もアカウントごとに 1 つ
   leterejo ──→ notmuch    一覧・本文・検索、そして状態の変更すべて
            └─→ himalaya   送信のみ
```

## 必要なもの

| | 用途 |
|---|---|
| Neovim 0.10 以降 | `vim.system`、行内の仮想テキスト |
| [notmuch][] | すべての読み取り元となる索引 |
| [lieer][] (`gmi`) | メールの取得と、変更の Gmail への反映 |
| [himalaya][] v2 | 送信 |
| `w3m` (任意) | 本文が HTML しかないメールの整形 |
| [snacks.nvim][] (任意) | メールが持つ画像の表示 |
| [fzf-lua][] (任意) | 選択窓の改善、タグ付けでの複数選択 |

## アカウントの用意

`:checkhealth leterejo` がその時点で足りないものを報告する。**最初に実行し、各段階のあとにも実行すること。**

**1. 機械的な部分はプラグインにやらせる**

```vim
:LeterejoSetup work
```

`~/Mail/work-lieer` を作り、`~/.config/notmuch/work` をそのアカウントの索引として書き、空の索引を作り、残りの手順を表示する。**既にあるものは上書きしない** (打ち間違えたアカウント名で既存の設定を壊さないため)。

**2. 認可と初回取得** — ブラウザとパスワードが要るので、ここは手で。

```sh
leterejo-env work gmi init you@example.com
leterejo-env work gmi auth        # ブラウザが手元に無いときは --noauth_local_webserver
leterejo-env work gmi set --timeout 60          # 既定は 10 分の無言
leterejo-env work gmi set --no-remove-local-messages
leterejo-env work gmi pull        # 全量。3 万通で 1 時間ほど
```

**必ず `leterejo-env` を通すこと。** 素で叩くと別アカウントの索引を触る。理由は [黙って壊れる 2 つのこと](#黙って壊れる-2-つのこと) を参照。

**3. プラグインに教える**

```lua
require("leterejo").setup({
  accounts = {
    work = {
      email = "you@example.com",       -- himalaya v2 はこれが無いと送信しない
      lieer_dir = "~/Mail/work-lieer",
      notmuch_config = "~/.config/notmuch/work",
    },
  },
  lieer = { interval = 5 },            -- 5 分ごとに取得
})
```

送信には himalaya 自身の設定も要る ([himalaya の文書][himalaya])。使うのは送信側だけ。

## 黙って壊れる 2 つのこと

**`new.tags` は空にする。** lieer は登録するファイルすべてに、Gmail のラベルに加えて notmuch の `new.tags` を付ける。既定は `unread;inbox` なので**全メールが受信箱・未読**になる。さらに悪いことに、Gmail が持たないタグは次の押し出しで Gmail に送られるので、**古いメールを 1 通保管しただけで受信箱に戻る**。`:LeterejoSetup` は空のものを書く。

**`XAPIAN_CJK_NGRAM=1` をすべての呼び出しに。lieer にも。** 付けずに登録すると、連続する日本語のかたまり全体が 1 語になり、その内側が引けなくなる。**2 文字の語は偶然通る**ので、短い語で試すと壊れに気づけない。プラグインは常に渡す。手で `gmi` や `notmuch` を叩くときは包み script を使う。

## キー

一覧画面:

| | |
|---|---|
| `<cr>` `r` `R` `f` `c` | 開く、返信、もう一方の返信、転送、新規作成 |
| `s` `F` | 既読・未読、印 |
| `e` `d` `S` | 保管、ごみ箱、迷惑メール |
| `t` `M` | タグの付け外し、別のタグへ移す |
| `m` `a` | タグを切り替える、アカウントを切り替える |
| `x` `o` | この行を選ぶ (ビジュアルでは範囲)、並び順を変える |
| `/` `g/` `<esc>` | 絞り込む、絞り込みを選ぶ、選択を外す→絞り込みを解除 |
| `A` `D` | 添付、保存した下書き |
| `H` `gH` | ヘッダ全体、メール全体 (届いたまま) |
| `p` `u` `?` `q` | 本文の追従、取得して読み直す、キー一覧、閉じる |
| `l` `h` `<tab>` | やり取りを開く・閉じる・切り替える |

どの操作も、`x` で選んだ行があればそれに対して、無ければカーソル行に対して働く。「選択に対して行う」ための 2 つ目のキーは無い。50 通への変更は、タグ付け 1 回と押し出し 1 回であって、同期 50 回ではない。

並び順: 新しい順・古い順は索引そのものの仕事で、どれだけ大きなメールボックスでも成り立つ。差出人順と件名順はそうではない (notmuch は日付でしか並べない) ので、一覧を最後まで読み込む必要があり、`sort_scan_limit` を超えるときは、たまたま読み込めた分だけを並べるのではなく断る。

作成画面: `<leader>hs` 送信、`<leader>hw` (または `:w`) 下書き保存、`<leader>hu` サーバに控えを置く、`<leader>ha` アドレス候補、`<leader>hg` 署名を選ぶ、`<leader>hq` 破棄。ヘッダ欄では `Enter` が次の項目へ、`dd` がその項目を空にする。転送は元メールが持っていた添付を Attach 欄に取り出して一緒に送る。

## できないこと

- **IMAP は使わない。** 読めるのは手元の索引にあるものだけ
- **受信箱は Gmail の「メイン」タブではない** (そうする気もない)。`INBOX` が付いた全部が入る。タブを取り込みたければ `gmi set --ignore-tags-remote ""` と全量 pull 1 回でふつうのタグとして入り、`g/` に「メイン相当」の見え方が出る。ただし**受信箱の定義は変えない** — 分類器の推測は、自分で選ぶ絞り込みであって、見えないものを決める既定ではない
- **Gmail に書き込むのはタグと送信だけ。** フィルタも設定も、本当の削除も行わない

## 設定

導入後は `:help leterejo` でも同じ内容が読める (`set helplang=ja` で日本語版)。

すべての項目は定義箇所 ([`lua/leterejo/config.lua`](lua/leterejo/config.lua)) に説明がある。よく使うもの:

| | |
|---|---|
| `lang` | 画面の言語 (`"en"` / `"ja"`) |
| `message_lang` | **メールの中に入る**文言 (引用行、転送の見出し) |
| `templates` `signature` `signatures` `quote` | 新しいメールが何で始まるか |
| `lieer.interval` | 取得の間隔 (分)。0 で行わない |
| `sort` `sort_scan_limit` | 一覧の初期の並び順と、notmuch にできない並びのために読む上限 |
| `preview` `preview_min_width` | 本文がカーソルに追従するか |
| `attachment_handlers` | 保存した添付をどう開くか |

## 設計ノート

[design-notes.ja.md](design-notes.ja.md) に、どう考えてここに至ったかと、途中で測ったものが残してある。一晩を費やした事柄も含む — himalaya の Maildir 対応が IMAP より遅かったこと、Gmail の帯域制限、初回取得を全量 pull にする理由、lieer が押し出しを拒むときに何が起きるか。

[notmuch]: https://notmuchmail.org/
[lieer]: https://github.com/gauteh/lieer
[himalaya]: https://github.com/pimalaya/himalaya
[snacks.nvim]: https://github.com/folke/snacks.nvim
[fzf-lua]: https://github.com/ibhagwan/fzf-lua
