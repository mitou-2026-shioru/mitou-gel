# GelLink — 触覚ゲルインタフェース

Apple Watchの心拍や日本語の音声・テキストを、温度・硬さの正規化2軸 `[0,1]²` に変換してM5Stackへ送る、iOS / watchOSのネイティブアプリです。SwiftUI、HealthKit、WatchConnectivity、URLSessionと、iPhoneの端末内Core ML音声認識用WhisperKit 1.1.0を使用します。

## 作成済みの機能

- Watch: ユーザーが開始・終了するマインド＆ボディ計測セッション、心拍取得、測定日時付きのiPhone同期。
- iPhone: 心拍グラフ、最新値、30秒平均、120秒履歴、個人ベースライン、60秒の上昇・下降傾向。
- 入力モード: Watchのライブ入力、模擬心拍、ことば（音声・テキスト）、温度・硬さの手動操作。
- 端末内音声: 多言語Whisper Base / Tiny / Turbo、8秒の音声窓、日本語文字起こし、互換Core MLフォルダの持ち込み。初回のモデル・トークナイザ取得以外は端末内処理。
- 声の特徴: 2秒窓の相対的な強さ・抑揚・間を触覚候補に変換。この候補処理は学習モデル不要。「声だけ」「ことばだけ」「ことば＋声」を選択可能。
- マイク: 音声設定で通常録音・特徴計測と内蔵マイクの向きを選択。診断表示で実際の入力経路、RMS・peak、受信秒数、解析待ちの破棄数を表示。
- 音声分類: tiny-lm由来の学習済み68特徴MLPをCore MLで実行。6クラスの確率、ラッセル座標、時間減衰・外れ値抑制を参考表示。分類結果は温度・硬さ指令へ直結させません。
- 表現分析: 日本語の手がかり辞書と簡易否定からvalence / arousalを生成。根拠を表示し、実際の感情は断定しません。文字入力はモデルなしで試せます。
- 時間窓: 触覚候補の直近10 / 30 / 60秒サンプル平均を、単調時計の固定2秒周期で送信。遅れた周期は飛ばします。手動は平均を通しません。
- UI: オリジナルのゲルの相棒「ぷに」、呼吸・まばたき、温度による色と硬さによる形の変化。Watchへ触覚プレビューを返す双方向通信。
- 表示: 通常画面は操作と結果を中心に表示。技術情報は初期状態オフの診断表示、音声設定は専用画面、安全・プライバシー情報は設定内に配置。
- 状態変換: `Input → InternalState → HapticState → DeviceCommand` を分離。
- デバイス: Wi-Fi HTTP JSON通信、接続確認、再接続、命令の応答照合、実測温度・圧力・状態表示。
- M5ポンプ・ヒーター: `m5-dual-control` v3のLAN通信にも対応。8桁LAN PIN、450ms周期の生存確認、実測温度・適用ポンプ設定・ヒーター状態を表示。設定で従来のGelLink APIと切り替えます。
- 停止: 有効な入力がない（心拍・文字30秒、声6秒の鮮度確認）、通信断、デバイス異常、入力切替、バックグラウンド移行で出力停止。再開は利用者の操作で行います。
- 評価: 温度3段階×硬さ2段階のランダム提示順、匿名ID、温かさ・硬さの7段階評価、自由記述、CSV共有。
- ログ: センサ、内部状態、目標、実測、命令IDを記録し、CSV共有。メモリ内で最大1800行を保持します。

**M5Stackとの連携、温度制御、ジャミングによる硬さ制御を実証済みです。** 音声分類を含むiOSと埋め込みWatchのSDKビルド、45件のCoreテスト、Core ML変換とPython版との一致を確認済み。iPhone 17eでは0.3.2 / build 5、実Apple Watchでは0.2.0 / build 2の署名・インストール・起動を確認済みです。

追加仕様・モデルの扱い・オフライン検証は [ことば入力と時間窓](docs/VOICE_AND_WINDOW.md)、実証・テストの結果は [実証・テスト結果](docs/VALIDATION.md) を参照してください。[デザイン検討図](docs/design-preview.png) はコードから描画したレイアウト検討用の画像です。

## Xcodeで起動

実機導入環境: Xcode 27.1 RC / macOS 26.7.1。アプリの対象はiOS 17以降、watchOS 10以降。Swift Packageの取得にネットワークが必要です。実心拍の確認にはペアリング済みiPhoneとApple Watchが必要です。

1. `GelLink.xcodeproj` を開きます。
2. プロジェクトのBuild Settingsで `GELLINK_BUNDLE_ID` を自分の一意なIDに変更します。iOSとWatchのBundle ID、Watch側のcompanion設定が連動します。
3. `GelLink` と `GelLinkWatch` の両ターゲットのSigning & Capabilitiesで、自分の開発Teamを指定します。HealthKit capabilityは設定済みです。プロビジョニングでHealthKitを利用できるTeamを使用してください。
4. `GelLink` schemeでiPhoneへ実行します。実機ではDeveloper Modeを有効にします。
5. `GelLinkWatch` schemeでペアリング済みApple Watchへ実行します。
6. iPhoneの「設定」でヘルスケアアクセスを設定し、必要な読み取りを許可します。
7. iPhoneの「相棒」で `Watch` を選択し、Watchで「計測を開始」を押し、Watch側のHealthKit権限も許可します。
8. iPhoneは前面に開いておきます。心拍が届いたら「現在の状態でベースラインを校正」を実行できます（直近30秒に3件以上必要）。
9. iPhoneの「設定」でM5StackのLAN URLを指定し「接続 / 再接続」。その後「ゲル」で「出力開始」を押します。
10. 終了時はiPhoneで「停止」、Watchで「計測を終了」。Watchの計測はヘルスケアにワークアウトとして保存されます。

実機の起動・署名設定はアカウントと端末に依存するため、開発Teamをソースに固定していません。

このMacの実機設定はGit管理外の `Config/Local.xcconfig` に保持できます。`Config/Defaults.xcconfig` から読み込み、両ターゲットで同じTeamとBundle IDを使用します。プロジェクト再生成後もローカル設定は保持されます。

iPhoneと実Watchの準備手順は [実機セットアップ](docs/REAL_DEVICES.md) を参照してください。

## 実機なしで試す

1. iPhone Simulatorで `GelLink` を実行します。初期モードは「模擬入力」です。
2. ターミナルで次を実行します。

```sh
cd /Users/kataiwa/mitou-gel
python3 tools/mock_m5stack.py
```

3. アプリの「設定」で `http://127.0.0.1:8080` を指定し、接続します。
4. 「ゲル」で出力を開始します。「相棒」の模擬心拍スライダーを変更すると、時間窓の平均と触覚指令が変わります。
5. 「手動」を選ぶと温度と硬さを独立操作できます。モード変更では出力が停止するため、再度出力を開始します。
6. 「記録」で6条件の操作とCSV書き出しを試せます。CSVには `simulated=true` が残るため、実機の評価データと区別できます。
7. 「ことば」の文字入力や「安心」「緊張」サンプルで、モデルなしで別入力からの触覚表現も試せます。モード変更後の出力再開は手動です。

実機iPhoneからMacの模擬サーバーへ接続する場合は `python3 tools/mock_m5stack.py --host 0.0.0.0` で起動し、iPhoneとMacを同一LANに接続してMacのLAN IPとポート8080を指定します。初期設定の127.0.0.1はiPhone自身を指します。

## m5-dual-controlのM5へ接続する

1. M5側の`NetworkConfig.h`に実際のWi-Fi設定を記入して書き込み、iPhoneを同じLANへ接続します。
2. GelLinkの「設定 → 接続方式」で「M5ポンプ・ヒーター」を選びます。
3. M5画面の`http://192.168.…`（または`http://m5-control.local`）と、8桁の「LAN PIN」を入力して接続します。URLにAPIパスを付けません。PINは端末に保存せず、M5の再起動後は新しいPINで再接続します。
4. 「ゲル」で入力を「手動」にし、表示される目標温度・ポンプ設定を確認して「出力開始」を押します。接続だけでは出力を開始しません。
5. 終了時は「停止」。M5本体Bでも停止できます。他のブラウザ等で操作中なら先にそちらで切断するか本体Bで解除してください。

温度指令は`25 + 25 × temperature`℃、硬さ指令はポンプ電流設定の最寄りの`0 / 0.38 / 0.71 / 1`へ変換します。ポンプ設定は実測圧力や硬さではありません。温度0は25℃の目標であり、加熱停止には「停止」を使います。出力開始で温度制御も開始し、更新ではヒーターを自動再開しません。

触覚候補の平均・更新は従来どおり2秒周期です。それとは独立して450ms周期でM5へ生存確認を送り、M5側は2秒の通信途絶で停止します。バックグラウンド移行、設定・入力変更では停止・操作権の解放を送信して生存確認も終了します。M5実機用ファームウェアは別管理です。詳細は[通信仕様](docs/DEVICE_PROTOCOL.md#m5-dual-control-v3のlan接続)を参照してください。

## 状態とマッピング

```text
Apple Watch / HKLiveWorkoutBuilder
   ↓ WatchConnectivity（測定日時付き、最新状態を優先）
iPhone / SignalPipeline
   ↓ 30秒平均・ベースライン差・60秒傾向
InternalState / arousal
   ↓ HapticMapping
HapticState / temperature, stiffness
   ↓ 触覚候補の10 / 30 / 60秒サンプル平均（手動は省略）
   ↓ HTTP API v1（2秒周期、6秒TTL）
M5Stack / 物理制御・フィードバック・安全停止
```

初期の探索用マッピングは以下です。感情分類ではなく、個人内の心拍変化を触覚へ割り当てる仮説です。

```text
arousal     = clamp(0.5 + (30秒平均心拍 - 個人ベースライン) / 60, 0, 1)
temperature = 0.25 + 0.5 * arousal
stiffness   = arousal
```

初期ベースラインは70 bpmです。直近30秒の平均で校正するか、HealthKitから取得した安静時心拍を利用者の操作で適用します。HRVは測定日時付きで表示し、5分以内の値だけを内部状態の補助情報として保持します。HRVをストレス・リラックスの判定へ固定的に割り当てていません。別入力に切り替えると履歴を消去し、模擬値と実測値を混ぜません。

触覚候補の経路は `Audio / Text → ConversationSignal + VoiceSignal → ExpressionMapping → HapticState → 時間窓 → DeviceCommand` です。文字だけなら、手がかりがあれば `temperature = 0.25 + 0.5 × valence`、`stiffness = arousal`、なければ中立 `(0.5, 0)`。これは探索用の表現ルールで、分類モデルのラッセル座標ではありません。声は相対的な強さ・抑揚・発話の連続性を別経路で割り当て、選択モードで融合します。

音声分類の経路は `Audio → 68特徴 → AudioEmotionModel → クラス確率 → ラッセル座標 → UI / CSV` です。**認識結果は表示・記録、触覚指令はExpressionMappingで生成する別経路です。** アプリに同梱する音声分類モデルは68特徴MLP、文字起こしはWhisperKit対応モデルを使用します。

変換元は `mitou-2026-shioru/tiny-lm` の `public/circumplex-model.json`。モデルと出典情報は `iOS/Models/`、再変換は `tools/convert_circumplex.py` に保存しています。上流にLICENSEファイルはありません。モデルを配布する際は上流の利用条件を確認してください。

## ファイル構成

```text
Core/          入力モデル、時間窓処理、触覚マッピング、通信モデル、CSV
Shared/        HealthKitクエリ、WatchConnectivity、ゲルの相棒SwiftUI
iOS/           iPhoneアプリ、画面、統合ロジック、HTTPクライアント
Watch/         Watchアプリ、計測セッション
Config/        Info.plist、HealthKit entitlements
Tests/         Swiftの信号処理テスト
tools/         プロジェクト再生成、模擬M5Stack、通信テスト、ASRSmoke、デザイン描画
docs/          通信仕様、要件対応、実機操作・評価チェックリスト
```

`Core` はSwift Packageとして単独テストでき、同じSwiftファイルを両アプリでも使用します。入力の解釈、触覚マッピング、物理デバイス固有の制御を分離しています。Xcodeプロジェクトは作成済みです。Swiftファイルの追加時に `python3 tools/generate_project.py` で再生成できます。再生成では手動編集したプロジェクト設定を上書きするため、TeamやIDなどの変更は必要に応じて再設定してください。

## 検証コマンド

```sh
swift test
python3 -m unittest discover -s tools -p 'test_*.py'
xcodebuild -project GelLink.xcodeproj -scheme GelLink \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GelLink.xcodeproj -scheme GelLinkWatch \
  -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath build-watch CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GelLink.xcodeproj -target GelLink -configuration Debug \
  SYMROOT=/Users/kataiwa/mitou-gel/build-device/Products \
  OBJROOT=/Users/kataiwa/mitou-gel/build-device/Intermediates \
  CODE_SIGNING_ALLOWED=NO build
```

schemeの検証は対応するwatchOSコンポーネントの導入を求める場合があります。XcodeのSettings → Componentsで導入してください。最後のコマンドは各ターゲットのSDK設定を使って直接ビルドする方法です。

## 統合時に把握しておく動作

- ライブ心拍はWatchの計測セッションとWatchConnectivityを使用し、iPhoneのHealthKit取得は補助経路として10秒ごとに行います。
- Watchの `sendMessage` は到達可能時に送信し、`updateApplicationContext` は最新状態の同期に使います。古い順序のサンプル・重複・不正値を除外します。
- HealthKitの画面には「アクセス設定完了」を表示します。読み取りデータの有無は受信値で確認します。
- iPhoneがバックグラウンドに移行すると出力を停止します。通信断時の停止条件はM5Stack側の6秒TTLです。
- HTTPリクエストは単調時計の固定2秒周期です。遅れた周期はまとめて送らず飛ばし、処理時間による周期の積み上げを避けます。通信断から戻ると状態確認は再試行しますが、出力の自動再開は行いません。
- Wi-Fiは隔離した実験LANを使用します。アプリの接続先はプライベートIPv4・localhost・`.local` に制限し、HTTPリダイレクトは拒否します。ローカルHTTPを使用するため、ローカル名前解決とプライベートIP範囲のATS例外を設定しています。
- 温度指令から℃、硬さ指令から圧力への変換と安全範囲はM5Stack側の校正表で定義します。温度の下限は搭載する加熱・冷却機構に対応します。
- 模擬サーバーは `simulated=true`、実測値nullを返します。実機と模擬入力は画面・CSVのフラグで識別します。
- 音声はメモリ内のみで保存・送信せず、文字起こし本文も信号CSVに含めません。記録はアプリ終了で失われます。CSVは一時ディレクトリに作成し、共有コピーの管理は共有先で行います。モデルキャッシュは端末に残ります。

## Apple公式資料

- [Running workout sessions](https://developer.apple.com/documentation/healthkit/running-workout-sessions)
- [WCSession](https://developer.apple.com/documentation/watchconnectivity/wcsession)
- [updateApplicationContext](https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:))
- [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [heartRateVariabilitySDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)
- [NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)
