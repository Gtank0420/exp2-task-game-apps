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
- ゲームは音を出さず、文字を読む要素を入れず、既存の有名ゲームの見た目を真似ない
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
