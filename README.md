# DUPDEL

`dupdel.pl` は、指定フォルダ内の重複ファイルを検出し、必要に応じて削除する Perl スクリプトです。

重複判定は、ファイルサイズで絞り込んだあと SHA-1 ハッシュで行います。`--delete` を付けない場合は dry-run として動作し、実際には削除しません。

## 使い方

```text
perl dupdel.pl 対象フォルダ
perl dupdel.pl --delete 対象フォルダ
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
- `-d N`: 基準フォルダから見てちょうど `N` 階層下の各フォルダを独立に処理します。`N=0` は葉フォルダのみです。
- `-D N`: 1 階層下から `N` 階層下までの各フォルダを独立に処理します。`N=0` はすべてのサブフォルダです。
- `-s`: `-d` または `-D` と組み合わせたとき、基準フォルダ自身も処理対象に含めます。
- `-p STRING`: `STRING` を含むファイルを削除側へ寄せます。正規表現ではなく文字列の部分一致です。
- `-e REGEX`: ファイル名が `REGEX` にマッチするファイルを削除候補から除外します。判定対象はフルパスではなくファイル名のみです。
- `-r`: ファイル名の逆順で keep を決めます。

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
