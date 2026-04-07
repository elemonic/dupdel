# DUPDEL

`dupdel.pl` は、指定フォルダ内の重複ファイルを検出し、必要に応じて削除する Perl スクリプトです。

重複判定は、ファイルサイズで絞り込んだあとハッシュで行います。デフォルトのハッシュ方式は sha256 です。`--delete` を付けない場合は dry-run として動作し、実際には削除しません。

## 使い方

```text
perl dupdel.pl 対象フォルダ
perl dupdel.pl --delete 対象フォルダ
perl dupdel.pl -F 対象フォルダ
perl dupdel.pl -F --delete 対象フォルダ
perl dupdel.pl --hash sha256 対象フォルダ
perl dupdel.pl -H sha1 対象フォルダ
perl dupdel.pl -d N 対象フォルダ
perl dupdel.pl -D N 対象フォルダ
perl dupdel.pl -p STRING 対象フォルダ
perl dupdel.pl -e REGEX 対象フォルダ
perl dupdel.pl -r 対象フォルダ
perl dupdel.pl -p STRING -r 対象フォルダ
perl dupdel.pl -e REGEX -p STRING -r 対象フォルダ
perl dupdel.pl -d N -s 対象フォルダ
perl dupdel.pl -D N -s 対象フォルダ
```

## オプション

- `--delete`: 重複ファイルを実際に削除します。指定しない場合は dry-run です。
- `--hash ALG`: 重複判定に使うハッシュ方式を指定します。`ALG` は `sha1` / `sha256` / `blake2` / `blake3` です。
- `-H ALG`: `--hash ALG` の短縮指定です。
- `-F`: 対象フォルダ直下の子フォルダ同士を比較し、完全一致している重複フォルダを検出します。
- `-d N`: 基準フォルダから見てちょうど `N` 階層下の各フォルダを独立に処理します。`N=0` は葉フォルダのみです。
- `-D N`: 1 階層下から `N` 階層下までの各フォルダを独立に処理します。`N=0` はすべてのサブフォルダです。
- `-s`: `-d` または `-D` と組み合わせたとき、基準フォルダ自身も処理対象に含めます。
- `-p STRING`: `STRING` を含むファイルを削除側へ寄せます。正規表現ではなく文字列の部分一致です。
- `-e REGEX`: ファイル名が `REGEX` にマッチするファイルを削除候補から除外します。判定対象はフルパスではなくファイル名のみです。
- `-r`: ファイル名の逆順で keep を決めます。

## ハッシュ方式

ハッシュ方式のデフォルトは `sha256` です。

```text
perl dupdel.pl --hash sha256 対象フォルダ
perl dupdel.pl --hash sha1 対象フォルダ
perl dupdel.pl --hash blake2 対象フォルダ
perl dupdel.pl --hash blake3 対象フォルダ
perl dupdel.pl -H sha256 対象フォルダ
```

`sha1` と `sha256` は `Digest::SHA` を使います。`blake2` は CryptX の `Crypt::Digest` が利用できる環境で使えます。`blake3` は動作未確認扱いで、利用するには `Digest::BLAKE3` が必要です。

必要なモジュールがない場合は、別の方式へ黙ってフォールバックせず、エラーで終了します。

## フォルダ重複削除

`-F` を付けると、指定フォルダ直下の子フォルダ同士を比較します。

```text
perl dupdel.pl -F 対象フォルダ
perl dupdel.pl -F --delete 対象フォルダ
```

比較対象は子フォルダの直下ファイルのみです。直下にあるファイル名集合と、対応する各ファイルの内容が一致した場合に、同一フォルダとして扱います。

サブフォルダを含む子フォルダは比較対象外です。画面とログには `サブフォルダを含むためスキップ` の趣旨で出力します。

`--delete` を付けた場合、delete 側フォルダをいきなり削除せず、まずフォルダ内の直下ファイルを削除します。空になったことを確認できた場合だけ、そのフォルダ自体を削除します。

`-e REGEX` と組み合わせた場合、重複フォルダグループ内に除外 regex へマッチするファイルが含まれていれば、そのグループのフォルダ削除全体をスキップします。

フォルダ重複削除では、削除予定サイズ合計、実削除サイズ合計、削除失敗サイズ合計を bytes で表示します。サイズはフォルダ自体ではなく、削除対象ファイルの合計です。

## 削除除外 regex

`-e REGEX` にマッチしたファイルは、重複していても削除されません。

例:

```text
perl dupdel.pl -e "desktop\.ini" 対象フォルダ
```

この指定では、`C:\work\a\desktop.ini` も `D:\tmp\b\desktop.ini` も、判定対象は `desktop.ini` の部分だけです。

除外は keep 優先ではなく delete 禁止として扱います。そのため、除外にマッチした重複ファイルが複数ある場合は、重複が複数残ることがあります。

## ログ

`--delete` を付けて実行した場合、`yyyymmdd-DUPDEL.log` に UTF-8 で追記します。削除失敗時は keep/delete の対応、エラー内容、発生時刻をログ末尾の `削除失敗一覧` に出力します。

## Windows

Windows では `Win32::LongPath` を利用できる場合に長いパスへ対応します。非 Windows 環境では Perl の標準ファイル操作へフォールバックします。
