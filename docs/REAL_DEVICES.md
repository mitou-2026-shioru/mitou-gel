# iPhone / Apple Watchの実機セットアップ

## 実機構成と実証結果

- 開発環境はmacOS 26.7.1 / Xcode 27.1 RC。
- iPhone 17eでGelLink 0.3.2 / build 5の署名、上書きインストール、起動を確認済み。操作と結果を中心に表示し、マイク・モデル設定を別画面、入力経路などを診断表示に集約している。
- 実Apple Watchでは0.2.0 / build 2の署名・インストール・起動を確認済み。
- WatchのDeveloper Mode、開発用イメージの互換性、ライブ心拍と「iPhoneへ送信済み」の表示を確認済み。
- Watch用の開発プロファイルには実WatchとiPhoneのUDIDが含まれる。
- M5Stackとの連携、温度制御、ジャミングによる硬さ制御を実証済み。実証結果は[実証・テスト結果](VALIDATION.md)に記載する。

## 開発ツールと署名

`GelLink.xcodeproj`をXcodeで開く。アプリはiOS 17以降、watchOS 10以降を対象とする。接続端末のOSに対応するSDKと開発用イメージが必要。

両ターゲットで同じ開発Teamを選択する。Bundle IDとTeamのローカル設定はGit管理外の`Config/Local.xcconfig`へ保存する。HealthKit capabilityは設定済み。

Personal Teamの開発プロファイルには有効期限がある。期限はプロファイルで確認し、失効した場合は再署名・再インストールする。開発署名は配布用ビルドではない。

## 接続・実行

1. iPhoneをUSB接続してロックを解除し、Macへの信頼を許可する。
2. iPhoneとWatchをペアリングする。
3. 両端末の「設定 → プライバシーとセキュリティ」でDeveloper Modeを有効にし、再起動後の確認を行う。
4. XcodeのDevice Hubで開発ペアリングを確認する。端末のPINやApple Accountの認証は利用者本人が入力する。
5. `GelLink` schemeで実iPhoneへ実行する。
6. `GelLinkWatch` schemeで実Watchへ実行する。Simulatorとは区別する。
7. iPhoneの入力を「Watch」にし、Watchで「計測を開始」を押す。必要なHealthKitアクセスを許可する。
8. iPhoneを前面に置き、測定時刻と最新心拍の更新を確認する。

HealthKitの読み取り許可の拒否とデータ不在は区別できない。アプリのアクセス設定完了表示だけで読み取り許可済みとは判定しない。Watchの計測終了時にはワークアウトを保存する。

## 音声入力

- 「ことば」→「声だけ」ではWhisperの準備なしでマイク入力と声の特徴を使える。
- マイクは「通常録音」「画面側」を初期設定とする。「ことば」右上の音声設定から処理・向きを選択する。「診断表示」で入力経路、RMS・peakのdBFS、受信秒数を確認できる。
- 学習済み音声分類モデルはiPhoneへ同梱する。分類・ラッセル座標の参考表示と触覚指令は分離する。
- 文字起こしを使う場合はWhisperモデルとトークナイザを準備する。初回取得にはインターネット接続が必要。
- マイク許可は「話しかける」の操作で求める。バックグラウンドや中断後は自動で録音を再開しない。

## M5Stackとの接続

iPhoneとM5Stackを同一の実験LANへ接続する。「設定」でM5StackのURLを指定して接続し、「ゲル」で別途出力を開始する。Mac上の模擬サーバーを使う場合、iPhoneからはMacのLAN IPを指定する。`127.0.0.1`はiPhone自身を指す。

使用時は物理デバイス側のTTL監視、温度・圧力保護、実測校正を確認する。目標値・実測値・Device Stateはアプリ上で表示する。デバイスの安全条件は[Device API](DEVICE_PROTOCOL.md)に記載する。

## 接続不良時の確認

- 端末のロック、USB接続、Developer Mode、開発ペアリング、SDK・開発用イメージ、署名対象のUDIDを確認する。
- Watchが「paired」でも、開発サービスの接続やインストール成功は別に確認する。
- Bluetoothの応答だけではネットワークトンネルの確立を保証しない。
- Watchの初期化やペアリング解除を通常の再試行手順にはしない。

[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)、[Xcode対応環境](https://developer.apple.com/xcode/system-requirements)を参照できる。
