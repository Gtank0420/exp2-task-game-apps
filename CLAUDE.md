# 実験2 アプリ (課題アプリとゲームアプリ)

卒業研究の実験2で使う2つのアプリ。設計の詳細は docs/context_exp2_design_final.md を参照 (アプリの仕様は9章) 。

- 課題アプリ (iPad) : 連続加算の出題と回答の記録、実験の手順の管理、AirPods の頭の動き (IMU) の記録
- ゲームアプリ (研究室の iPhone) : サボり用のミニゲーム2種類 (積み上げ型、2048 型) と、操作と端末の動きの記録

## 最優先

1. データを失わない
2. 実験後の処理のしやすさ
3. 実験者の操作の簡単さ
4. 見た目

## 守ること

- 実験の設計 (区間の長さと順番、出題の仕様、画面に出す情報、ゲームの仕様) を勝手に変えない。疑問があれば変更せずに質問する
- 課題アプリでは、残り時間と正答数をどの画面にも出さない
- 2つのアプリで、記録の形式 (ファイルの構成、時刻の扱い、被験者 ID の付け方) を共通にする
- 時刻は Unix 時刻 (ミリ秒) と、単調増加の時刻の両方で記録する
- 記録はすぐ保存する。既存の被験者データを上書きしない
- 設定値 (区間の長さ、数字の範囲、乱数の種など) は1か所にまとめる
- ゲームは文字を読む要素を入れず、既存の有名ゲームの見た目を真似ない。効果音は鳴らす (2026-11-07 に1台版、11-08 に2台版。合成した短い音で、既存のゲームの音を真似ない)
- アンケートは対象外。ただし終了後の2問は、課題アプリで参加者が答える (app_decisions #63)
- AirPods の IMU は、2026-11-04 から課題アプリが本番のセッションの中で記録する (app_decisions #72〜#74。既存の IMU アプリはやめ、当日の予備としてだけ使う)。途中で切れても参加者の画面には何も出さず、自動で戻すだけにする
- 実験の進行は、引き継ぎのあとは参加者が課題アプリの画面だけで進める (app_decisions #61)。参加者向けの文面はすべて ExperimentConfig.swift の ParticipantGuide に置き、画面のコードに書かない

## よく使うコマンド

- 2つのアプリと道具の見取り図 (最初に読む): docs/overview.md。アプリの構成や役割を変えたらこれも直す
- 設計書に加えて決めたこと: docs/app_decisions.md
- 実験者マニュアル (インストール、当日の操作、データの取り出し): docs/experimenter_manual.md。画面や操作を変えたらこれも直す
- 設定値はすべて1か所: 課題アプリは Packages/ExperimentCore/Sources/ExperimentCore/ExperimentConfig.swift、ゲームアプリは Packages/ExperimentCore/Sources/GameCore/GameConfig.swift、状態のラベルの閾値は tools/exp2/timeline.py の LabelParams
- 書き出すファイルの定義: docs/data_spec.md (列を変えたら、課題アプリは Records.swift (AirPods の記録は HeadphoneMotion.swift) と tools/exp2/schema.py、ゲームアプリは GameRecords.swift と tools/exp2/game_schema.py、それにこの仕様書を揃えて直し、schemaVersion を上げる)
- コードの置き場所: 2つのアプリで共通の記録の部品は Packages/ExperimentCore の RecordingCore、課題アプリは ExperimentCore と App/、ゲームアプリは GameCore と GameApp/、両方の画面の部品は Shared/、Python は tools/exp2/

```sh
xcodegen generate                                   # project.yml から Exp2Task.xcodeproj を作り直す
(cd Packages/ExperimentCore && swift test)          # 中核部分の単体テスト (Mac 上、シミュレータ不要)
.venv/bin/python -m unittest discover -s tools/tests   # Python 側のテスト (疑似データを swift run で作るので初回は遅い)
.venv/bin/python tools/validate_session.py <被験者フォルダ、exp2_data、exp2_game、またはその親> [--imu <.db>] [--quiet]
                                                    # データの検証 (課題アプリとゲームアプリのどちらのフォルダでもよい。AirPods の記録も見る。--imu は予備の既存アプリの記録)
python3 tools/exp2/sequence.py                      # 出題生成を変えたら、Swift テスト用の基準ファイルを作り直す
python3 tools/exp2/merge_game.py                    # 2048 型の規則を変えたら、同じく基準ファイルを作り直す
swift run --package-path Packages/ExperimentCore exp2-simulate --out samples/simulated --n 20
                                                    # 課題アプリの疑似参加者20人分を本番の長さで作る (約15秒)。同じ ID があれば止まる
.venv/bin/python tools/make_joint_sim.py --out <出力先> --n 20
                                                    # 2つのアプリと IMU (課題アプリの被験者フォルダに入る) の、時間の矛盾のない疑似データ (分析コードの開発用、1人約7秒)
.venv/bin/python tools/build_timeline.py <exp2_data と exp2_game の親> --out <出力先> [--figures]
                                                    # 2つのアプリの記録 (AirPods の記録を含む) を1本の時間軸に統合し、状態のラベルと5秒窓を書き出す
.venv/bin/python tools/check_headphone_test.py <exp2_imu_test/IMUTEST_... または exp2_data/<ID>> [--figure <png>] [--compare <既存アプリの .db>]
                                                    # AirPods の記録を詳しく確かめる (受け取りの遅れ、空き。app_decisions #71)
xcodebuild -project Exp2Task.xcodeproj -scheme Exp2Task \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build                     # シミュレータ向けビルド (ゲームアプリは -scheme Exp2Game)

# 実機 (iPad Pro 11 第3世代 / iPhone 12 Pro、USB 接続) への入れ直し。前後でデータを写して比べ、署名の期限を出す
.venv/bin/python tools/install_to_ipad.py <バックアップ先> [--app task|game] [--renew]   # --renew で署名を作り直し期限を7日延ばす
.venv/bin/python tools/pull_from_ipad.py <保存先> [--app task|game]   # USB で端末のデータを丸ごと写して検証 (AirDrop の予備)

# 画面の通し操作 (UI テスト、約7分)。前回のデータが残っていると再開画面が出るので、先にアプリを削除する
UDID=5CD01883-C578-46FD-9A05-4ED45588EB69           # iPad Pro 11-inch (M5) シミュレータ
xcrun simctl uninstall $UDID com.ryogashimizu.Exp2Task
TEST_RUNNER_SCREENSHOT_DIR=<保存先> xcodebuild -project Exp2Task.xcodeproj -scheme Exp2Task \
  -destination "id=$UDID" -derivedDataPath build/DerivedData -only-testing:Exp2TaskUITests test
```
```sh
# ゲームアプリの画面の通し操作 (UI テスト、約1分)。記録中のセッションが残っていると自動で開くので、先にアプリを削除する
UDID_IPHONE=EA6EDCCC-FCA2-45B2-A771-E8156AF5D31D    # iPhone 17e シミュレータ (画面の大きさが iPhone 12 Pro と同じ)
xcrun simctl uninstall $UDID_IPHONE com.ryogashimizu.Exp2Game
TEST_RUNNER_SCREENSHOT_DIR=<保存先> xcodebuild -project Exp2Task.xcodeproj -scheme Exp2Game \
  -destination "id=$UDID_IPHONE" -derivedDataPath build/DerivedData -only-testing:Exp2GameUITests test
```
(xcodebuild はテストが終わったあとも止まらないことがある。ログに `Executed 5 tests` (ゲームアプリは `Executed 2 tests`) が出ていれば終わっている)

## 1台版 (iPad 1台で、計算問題の途中にゲームが割り込む形式)

2台版の2つのアプリとは別の3つ目のアプリ「実験2一台」(Exp2Single、bundle ID com.ryogashimizu.Exp2Single、保存先 exp2_single)。
設計は docs/context_exp2_ipad_only.md (書いていないことは2台版の設計書に従う)、決めたことは docs/single_decisions.md (S1〜)、
書き出すファイルは docs/data_spec_single.md、当日の操作は docs/experimenter_manual_single.md。2台版の app_decisions.md、data_spec.md、experimenter_manual.md には書かない。
見取り図は docs/overview.md の9章 (1台版の構成や役割を変えたらこれも直す)。

- **2台版の2つのアプリの動き、画面、記録の形式を変えない。** (2026-11-08 に、ユーザーの指示で1台版の変更の一部を2台版にも入れた (app_decisions #75〜#80)。そのあとの2台版の基準は build/baseline_2dev_v2/。1台版の基準は build/baseline_single/ (2台版を直したら、1台版の疑似参加者の出力がこれとバイト単位で同じことも確かめる)) 2台版の記録の処理 (SessionController、Records、GameController、GameRecords など) は1台版のために直さない。共通の部品 (RecordingCore、App/ と GameApp/ の参照しているファイル、Shared/、tools/exp2 の2台版の関数) に手を入れたら、2台版のテストがすべて通ることと、2台版の疑似参加者の出力が2台版の基準 (2026-11-08 からは build/baseline_2dev_v2/。それより前は build/baseline_2dev/、main 3c24a35 で作成) とバイト単位で同じことを確かめる (app_decisions #27 と同じ確かめ方)。画面の部品に触れたら、2台版の UI テストも回す
- 設定値と参加者向けの文面は Packages/ExperimentCore/Sources/SingleCore/SingleConfig.swift の1か所 (ParticipantGuide.single、ExperimentTexts.single)。2台版と同じ値 (区間、出題、2つのゲームの規則) は2台版の設定から写して作る
- 列を変えたら SingleRecords.swift、tools/exp2/single_schema.py、docs/data_spec_single.md を揃えて直し、1台版の schemaVersion を上げる
- コードの置き場所: 中核は Packages/ExperimentCore の SingleCore、画面は SingleApp/ (2台版の画面の部品は project.yml でファイルを参照する)、Python は tools/exp2/single_*.py
- 被験者 ID: 本番 S01、予備実験 SPILOT01、開発用 DEV_ (2台版の P01 は受け付けない)
- 1台版のゲームは効果音を鳴らす (2026-11-07 ユーザー判断。single_decisions S55。2台版も 2026-11-08 から鳴らす、app_decisions #76)
- 説明の音声 (ElevenLabs で作った mp3) は、1台版は SingleApp/SpeechAudio/、2台版の課題アプリは App/SpeechAudio/ に置く (原稿は docs/speech_scripts_single.md、speech_scripts_2dev.md)。**公開しないので git に入れない** (.gitignore 済み。プロジェクトにも名前を載せず、ビルドのたびにスクリプトでアプリに写す。single_decisions S53)

```sh
(cd Packages/ExperimentCore && swift test --filter SingleCoreTests)   # 1台版の中核の単体テスト
swift run --package-path Packages/ExperimentCore exp2-single-simulate --out <出力先> --n 20 [--short|--quick] [--interrupt-popup]
                                                    # 1台版の疑似参加者20人分を本番の長さで作る (約15秒)。同じ ID があれば止まる
.venv/bin/python tools/validate_session.py <exp2_single、その被験者フォルダ、またはその親>   # 1台版も自動で見分ける (meta.json の app_kind)
.venv/bin/python tools/make_single_sim.py --out <出力先> --n 20   # 1台版と IMU の、時間の矛盾のない疑似データ (正解つき、1人約3秒)
.venv/bin/python tools/build_single_timeline.py <exp2_single の親> --out <出力先> [--figures]
                                                    # 1台版の記録を1本の時間軸に並べ、状態のラベルと5秒窓を書き出す (閾値は single_timeline.py の SingleLabelParams)
xcodebuild -project Exp2Task.xcodeproj -scheme Exp2Single \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

# 実機の iPad への入れ直しと取り出し (同じ Wi-Fi でもよい。2台版の課題アプリと同じ iPad に並べて入る。もう片方のデータには触れない)
.venv/bin/python tools/install_to_ipad.py <バックアップ先> --app single [--renew]
.venv/bin/python tools/pull_from_ipad.py <保存先> --app single

# 1台版の画面の通し操作 (UI テスト、約3分)。前回のデータが残っていると結果が変わるので、先にアプリを削除する
xcrun simctl uninstall $UDID com.ryogashimizu.Exp2Single
TEST_RUNNER_SCREENSHOT_DIR=<保存先> xcodebuild -project Exp2Task.xcodeproj -scheme Exp2Single \
  -destination "id=$UDID" -derivedDataPath build/DerivedData -only-testing:Exp2SingleUITests test
```
