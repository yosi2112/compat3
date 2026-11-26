# COMPAT3

PC Engine 用システムカード BIOS のクリーンルーム実装です。HuC6280 アセンブラで記述し、システムカードのジャンプテーブル81スロットをすべて実装しています。実在の BIOS のコードやデータは一切含んでいません。

## 概要

- 256KB（32バンク）の Super CD-ROM² 対応システムカードイメージ
- CD-ROM BIOS、ADPCM、バックアップメモリ、フォント表示（EX_GETFNT）、PSG／グラフィック／キー等の各 BIOS を含む
- 動作確認：自作テスト一式に合格し、市販の Super CD-ROM² タイトル4本の起動を確認（CSCP コア上）

## ビルド

要件：cc65（ca65 / ld65）、Python 3（フォント変換用）

```
make
```

`build/COMPAT3.PCE`（262,144 バイト）が生成されます。中間ファイル（オブジェクト、フォント中間データ）はビルド完了時に自動で削除され、`build/` に残るのは `COMPAT3.PCE` のみです。

## 構成

- `src/` — アセンブラソース
- `cfg/` — リンカ設定（compat3.cfg）
- `fonts/` — KHドットフォント（下記）
- `tools/` — フォント変換スクリプト
- `build/` — 生成物

## フォント

EX_GETFNT のグリフには KHドットフォント（`fonts/` に収録）を使用しています。フォントは SIL Open Font License 1.1 の下で提供されます（`fonts/SIL_Open_Font_License_1.1.txt` を参照）。グリフデータは `tools/` のスクリプトで TTF から変換されます。

## ライセンス

本体は MIT License です（`LICENSE` を参照）。フォントについては上記の通り SIL Open Font License 1.1 が適用されます。
