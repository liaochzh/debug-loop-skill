#!/bin/bash
# test_snapshot.sh — _snapshot_parse.py 离线回归（无需设备）
#
# 用法: bash scripts/test_snapshot.sh
# 覆盖: 三种方言字段映射 / 摘要截断 / --json 全量（第 41 节点命中）/ 畸形 XML / 语义树为空
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE="$SCRIPT_DIR/_snapshot_parse.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "❌ $1"; }
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望=$2 实际=$3)"; fi
}
expect_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 (未包含: $2)" ;;
  esac
}

# ---------- fixture: uiautomator ----------
cat > "$TMP/ui.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node class="android.widget.FrameLayout" text="" resource-id="" clickable="false" bounds="[0,0][1080,1920]"/>
  <node class="android.widget.TextView" text="订单列表" resource-id="com.demo:id/title" clickable="false" bounds="[24,100][600,160]"/>
  <node class="android.widget.Button" text="提交" resource-id="com.demo:id/submit" clickable="true" bounds="[800,1700][1050,1800]"/>
  <node class="android.widget.TextView" text="这是一段超过四十个字符的很长很长的文本用于验证摘要截断行为是否正确工作" resource-id="" clickable="false" bounds="[24,200][1000,260]"/>
</hierarchy>
XML

out=$(python3 "$PARSE" --input "$TMP/ui.xml" --json)
rc=$?
expect_eq "uiautomator rc=0" "0" "$rc"
expect_eq "uiautomator raw_nodes=4" "4" "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["raw_nodes"])' <<< "$out")"
expect_eq "uiautomator nodes=3（容器被丢弃）" "3" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
expect_contains "uiautomator text 提取" "订单列表" "$out"
expect_eq "uiautomator clickable" "True" "$(python3 -c 'import json,sys;print(any(n["clickable"] for n in json.load(sys.stdin)["nodes"]))' <<< "$out")"

summary=$(python3 "$PARSE" --input "$TMP/ui.xml")
text_len=$(printf '%s\n' "$summary" | grep '这是一段' | python3 -c 'import sys; line=sys.stdin.readline().rstrip("\n"); print(len(line.split("|")[2]))')
if [ "${text_len:-0}" -le 41 ]; then ok "摘要 text 已截断（${text_len} 字符）"; else bad "摘要 text 未截断（${text_len} 字符）"; fi

# ---------- fixture: XCUITest ----------
cat > "$TMP/xcui.xml" <<'XML'
<AppiumAUT>
  <XCUIElementTypeApplication name="Demo" label="Demo" x="0" y="0" width="390" height="844">
    <XCUIElementTypeStaticText name="title" label="订单列表" value="" x="16" y="50" width="200" height="20"/>
    <XCUIElementTypeButton name="submit" label="提交" x="300" y="700" width="70" height="40"/>
    <XCUIElementTypeOther name="" label="" x="0" y="0" width="390" height="844"/>
  </XCUIElementTypeApplication>
</AppiumAUT>
XML

out=$(python3 "$PARSE" --input "$TMP/xcui.xml" --json)
expect_eq "XCUITest rc=0" "0" "$?"
expect_eq "XCUITest nodes=2（容器被白名单剔除）" "2" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
expect_contains "XCUITest label→text" "提交" "$out"
expect_eq "XCUITest bounds 换算" "[300,700][370,740]" "$(python3 -c 'import json,sys;print([n["bounds"] for n in json.load(sys.stdin)["nodes"] if n["text"]=="提交"][0])' <<< "$out")"

# ---------- fixture: mac2 ----------
cat > "$TMP/mac2.xml" <<'XML'
<AXApplication AXTitle="Demo">
  <AXWindow AXTitle="">
    <AXButton AXTitle="提交" AXIdentifier="submit" AXFrame="[300,700][370,740]"/>
    <AXStaticText AXTitle="订单列表" AXFrame="[16,50][216,70]"/>
  </AXWindow>
</AXApplication>
XML

out=$(python3 "$PARSE" --input "$TMP/mac2.xml" --json)
expect_eq "mac2 rc=0" "0" "$?"
expect_eq "mac2 nodes=2" "2" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
expect_contains "mac2 AXTitle→text" "订单列表" "$out"

# ---------- fixture: maestro hierarchy --compact（iOS 模拟器实测路径） ----------
cat > "$TMP/maestro.csv" <<'CSV'
element_num,depth,attributes,parent_num
0,0,"bounds=[0,0][0,0]",
1,1,"accessibilityText=小瞳; bounds=[0,0][390,844]; enabled=true",0
2,9,"accessibilityText=Sign In; bounds=[24,658][366,708]; enabled=true",1
3,9,"accessibilityText=Sign Up; resource-id=signup; bounds=[25,725][364,772]; enabled=true",1
4,2,"bounds=[0,0][390,844]; enabled=true",1
CSV

out=$(python3 "$PARSE" --input "$TMP/maestro.csv" --json)
expect_eq "maestro rc=0" "0" "$?"
expect_eq "maestro raw_nodes=5" "5" "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["raw_nodes"])' <<< "$out")"
expect_eq "maestro nodes=3（无文本容器被丢弃）" "3" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
expect_contains "maestro accessibilityText→text" "Sign In" "$out"
expect_eq "maestro resource-id→id" "signup" "$(python3 -c 'import json,sys;print([n["id"] for n in json.load(sys.stdin)["nodes"] if n["text"]=="Sign Up"][0])' <<< "$out")"

# 文本内含 "; " 时不得被属性分隔误切
cat > "$TMP/maestro_semicolon.csv" <<'CSV'
element_num,depth,attributes,parent_num
1,1,"accessibilityText=保存成功; 请稍候; bounds=[0,0][10,10]; enabled=true",0
CSV
out=$(python3 "$PARSE" --input "$TMP/maestro_semicolon.csv" --json)
expect_contains "文本含 '; ' 不被截断" "保存成功; 请稍候" "$out"

# ---------- 畸形 XML ----------
printf '<hierarchy><node class="x"\n' > "$TMP/broken.xml"
python3 "$PARSE" --input "$TMP/broken.xml" > /dev/null 2>&1
expect_eq "畸形 XML rc=1" "1" "$?"

# ---------- 第 41 节点命中（摘要截断不得影响断言） ----------
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<hierarchy rotation="0">'
  i=1
  while [ "$i" -le 45 ]; do
    echo "  <node class=\"android.widget.TextView\" text=\"item$i\" resource-id=\"\" clickable=\"false\" bounds=\"[0,$i][100,$i]\"/>"
    i=$((i + 1))
  done
  echo '</hierarchy>'
} > "$TMP/many.xml"

out=$(python3 "$PARSE" --input "$TMP/many.xml" --json)
expect_eq "45 节点：--json 全量=45" "45" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
expect_contains "第 41 节点在 --json 中可见" "item41" "$out"

summary=$(python3 "$PARSE" --input "$TMP/many.xml" --max 40)
expect_contains "摘要标注剩余数量" "另有 5 个" "$summary"
case "$summary" in
  *item41*) bad "摘要不应包含第 41 节点（截断失效）" ;;
  *) ok "摘要按 --max 截断" ;;
esac

# ---------- 语义树为空（raw>0 且过滤后 0） ----------
cat > "$TMP/empty.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<hierarchy rotation="0">
  <node class="android.widget.FrameLayout" text="" resource-id="" clickable="false" bounds="[0,0][1080,1920]"/>
</hierarchy>
XML

python3 "$PARSE" --input "$TMP/empty.xml" > /dev/null 2>&1
expect_eq "语义树为空 rc=4" "4" "$?"

cat > "$TMP/empty_raw.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<hierarchy rotation="0"/>
XML

python3 "$PARSE" --input "$TMP/empty_raw.xml" > /dev/null 2>&1
expect_eq "空 dump（raw=0）rc=1 而非 4" "1" "$?"

# maestro 仅表头 CSV（App 未起 / 无障碍未开）也必须 exit 1
printf 'element_num,depth,attributes,parent_num\n' > "$TMP/maestro_empty.csv"
python3 "$PARSE" --input "$TMP/maestro_empty.csv" > /dev/null 2>&1
expect_eq "maestro 仅表头（raw=0）rc=1" "1" "$?"

# ---------- 断言层（_assert_page.py） ----------
python3 "$PARSE" --input "$TMP/ui.xml" --json > "$TMP/ui.json"

cat > "$TMP/a_pass.txt" <<'EOF'
# 正常路径
has 订单列表
count 订单 1
has-not 加载中
EOF
out=$(python3 "$SCRIPT_DIR/_assert_page.py" --file "$TMP/a_pass.txt" --platform android < "$TMP/ui.json")
expect_eq "断言全过 rc=0" "0" "$?"
expect_contains "断言 PASS 汇总" "3/3 PASS" "$out"

cat > "$TMP/a_fail.txt" <<'EOF'
has 订单列表
count 订单 3
EOF
out=$(python3 "$SCRIPT_DIR/_assert_page.py" --file "$TMP/a_fail.txt" --platform android < "$TMP/ui.json")
expect_eq "断言失败 rc=1" "1" "$?"
expect_contains "断言失败给出差异" "期望3 实际1" "$out"

cat > "$TMP/a_not.txt" <<'EOF'
has-not 提交
EOF
python3 "$SCRIPT_DIR/_assert_page.py" --file "$TMP/a_not.txt" --platform android < "$TMP/ui.json" > /dev/null
expect_eq "has-not 命中即失败 rc=1" "1" "$?"

# 第 41 节点可被断言命中（验证断言走全量而非摘要）
cat > "$TMP/a_41.txt" <<'EOF'
has item41
count item 45
EOF
python3 "$PARSE" --input "$TMP/many.xml" --json > "$TMP/many.json"
out=$(python3 "$SCRIPT_DIR/_assert_page.py" --file "$TMP/a_41.txt" --platform android < "$TMP/many.json")
expect_eq "第 41 节点断言 rc=0" "0" "$?"
expect_contains "第 41 节点断言 PASS" "2/2 PASS" "$out"

# ================= 第三阶段：center / _tap_target / tap_snapshot =================

# ---------- center 解析（四方言 + 负坐标 + 边界） ----------
center_of() {  # center_of <json_file> <text>
  python3 - "$1" "$2" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
for node in payload["nodes"]:
    if node["text"] == sys.argv[2]:
        c = node["center"]
        print("null" if c is None else "%d,%d" % (c[0], c[1]))
        break
else:
    print("missing")
PY
}

python3 "$PARSE" --input "$TMP/ui.xml" --json > "$TMP/ui2.json"
expect_eq "center: uiautomator 方括号" "312,130" "$(center_of "$TMP/ui2.json" "订单列表")"
python3 "$PARSE" --input "$TMP/xcui.xml" --json > "$TMP/xcui.json"
expect_eq "center: xcuitest" "335,720" "$(center_of "$TMP/xcui.json" "提交")"
python3 "$PARSE" --input "$TMP/maestro.csv" --json > "$TMP/maestro.json"
expect_eq "center: maestro" "195,683" "$(center_of "$TMP/maestro.json" "Sign In")"
python3 "$PARSE" --input "$TMP/mac2.xml" --json > "$TMP/mac2.json"
expect_eq "center: mac2 方括号" "335,720" "$(center_of "$TMP/mac2.json" "提交")"

cat > "$TMP/mac2_appium.xml" <<'XML'
<AXApplication AXTitle="Demo">
  <AXButton AXTitle="提交" AXIdentifier="submit" AXFrame="{{300.5, 700}, {70, 40}}"/>
</AXApplication>
XML
python3 "$PARSE" --input "$TMP/mac2_appium.xml" --json > "$TMP/mac2_appium.json"
expect_eq "center: mac2 {{x,y},{w,h}}" "335,720" "$(center_of "$TMP/mac2_appium.json" "提交")"

cat > "$TMP/bounds.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<hierarchy rotation="0">
  <node class="android.widget.TextView" text="neg" resource-id="" clickable="false" bounds="[-10,-20][30,40]"/>
  <node class="android.widget.TextView" text="zero" resource-id="" clickable="false" bounds="[100,100][100,200]"/>
  <node class="android.widget.TextView" text="garbage" resource-id="" clickable="false" bounds=""/>
  <node class="android.widget.TextView" text="garbage2" resource-id="" clickable="false" bounds="[a,b]"/>
</hierarchy>
XML
python3 "$PARSE" --input "$TMP/bounds.xml" --json > "$TMP/bounds.json"
expect_eq "center: 负坐标" "10,10" "$(center_of "$TMP/bounds.json" "neg")"
expect_eq "center: 零尺寸 ⇒ null" "null" "$(center_of "$TMP/bounds.json" "zero")"
expect_eq "center: 空 bounds ⇒ null" "null" "$(center_of "$TMP/bounds.json" "garbage")"
expect_eq "center: garbage bounds ⇒ null" "null" "$(center_of "$TMP/bounds.json" "garbage2")"

# ---------- --center 第 7 列 ----------
expect_eq "默认摘要无第 7 列" "6" "$(python3 "$PARSE" --input "$TMP/ui.xml" | awk -F'|' '!/^#/{print NF}' | sort -u | tr -d '\n')"
expect_eq "--center 全部 7 列" "7" "$(python3 "$PARSE" --input "$TMP/ui.xml" --center | awk -F'|' '!/^#/{print NF}' | sort -u | tr -d '\n')"
expect_eq "--center 第 7 列坐标" "312,130" "$(python3 "$PARSE" --input "$TMP/ui.xml" --center | grep '订单列表' | awk -F'|' '{print $7}')"
expect_eq "--center 无中心输出 -" "-" "$(python3 "$PARSE" --input "$TMP/bounds.xml" --center | grep '|garbage|' | awk -F'|' '{print $7}')"

# ---------- _tap_target.py ----------
TARGET="$SCRIPT_DIR/_tap_target.py"

cat > "$TMP/tap.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<hierarchy rotation="0">
  <node class="android.widget.TextView" text="Settings" resource-id="" clickable="false" bounds="[0,0][400,800]"/>
  <node class="android.widget.TextView" text="Add" resource-id="com.demo:id/add" clickable="true" bounds="[10,100][110,200]"/>
  <node class="android.widget.TextView" text="Add device" resource-id="com.demo:id/add_device" clickable="true" bounds="[10,300][110,400]"/>
  <node class="android.widget.TextView" text="Offscreen" resource-id="" clickable="true" bounds="[0,-200][100,-100]"/>
</hierarchy>
XML
python3 "$PARSE" --input "$TMP/tap.xml" --json > "$TMP/tap.json"

out=$(python3 "$TARGET" --text add < "$TMP/tap.json")
expect_eq "_tap_target 多命中 rc=0" "0" "$?"
expect_contains "多命中给出总数与序号" "命中 2 处，取第 1 处" "$out"
expect_contains "默认取第 1 处坐标" "center=(60,150)" "$out"
expect_contains "多命中附候选" "另有" "$out"

out=$(python3 "$TARGET" --text add --index 2 < "$TMP/tap.json")
expect_contains "--index 2 取第二处" "center=(60,350)" "$out"

out=$(python3 "$TARGET" --text add --index 99 < "$TMP/tap.json" 2>&1)
expect_eq "--index 越界 rc=1" "1" "$?"
expect_contains "越界提示命中总数" "越界（命中 2 处）" "$out"

out=$(python3 "$TARGET" --text Add --exact < "$TMP/tap.json")
expect_contains "--exact 只取全等" "命中 1 处" "$out"
python3 "$TARGET" --text add --exact < "$TMP/tap.json" > /dev/null 2>&1
expect_eq "--exact 大小写敏感 rc=1" "1" "$?"

out=$(python3 "$TARGET" --text add_device --id < "$TMP/tap.json")
expect_contains "--id 匹配 resource-id" "命中 1 处" "$out"
python3 "$TARGET" --text Settings --id < "$TMP/tap.json" > /dev/null 2>&1
expect_eq "--id 不看 text rc=1" "1" "$?"

out=$(python3 "$TARGET" --text zzz < "$TMP/tap.json" 2>&1)
expect_eq "_tap_target 未命中 rc=1" "1" "$?"
expect_contains "未命中给候选清单" "候选: Settings" "$out"

out=$(python3 "$TARGET" --text offscreen < "$TMP/tap.json")
expect_eq "离屏节点仍 rc=0" "0" "$?"
expect_contains "离屏给出 ⚠️" "疑似离屏" "$out"
out=$(python3 "$TARGET" --text Settings < "$TMP/tap.json")
expect_contains "非 clickable 给出 ⚠️" "clickable=false" "$out"

out=$(python3 "$TARGET" --text Settings --json < "$TMP/tap.json")
expect_contains "--json 输出 center" '"center": [200, 400]' "$out"
expect_contains "--json 输出 offscreen 字段" '"offscreen": false' "$out"
out=$(python3 "$TARGET" --text Settings --json < "$TMP/tap.json" 2>&1 1>/dev/null)
expect_contains "--json 的 ⚠️ 走 stderr" "clickable=false" "$out"
python3 "$TARGET" --text Settings --json < "$TMP/tap.json" 2>/dev/null | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
  && ok "--json stdout 是单行可解析 JSON" || bad "--json stdout 不是单行可解析 JSON"
out=$(python3 "$TARGET" --text offscreen --json < "$TMP/tap.json" 2>&1 1>/dev/null)
expect_contains "--json 离屏 ⚠️ 走 stderr" "疑似离屏" "$out"

printf '{"dialect":"uiautomator","nodes":[{"type":"x","text":"noCenter","id":"","bounds":"","clickable":true,"center":null}]}' \
  | python3 "$TARGET" --text noCenter > /dev/null 2>&1
expect_eq "选中项无 center rc=6" "6" "$?"
printf 'not-json' | python3 "$TARGET" --text x > /dev/null 2>&1
expect_eq "快照 JSON 不可解析 rc=5" "5" "$?"
python3 "$TARGET" --text x --index 0 < "$TMP/tap.json" > /dev/null 2>&1
expect_eq "--index 0 rc=2" "2" "$?"

# ---------- tap_snapshot.sh：--input / --dry-run 参数矩阵（不碰设备） ----------
TAP_SNAP="$SCRIPT_DIR/tap_snapshot.sh"

out=$(bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" 2>&1)
expect_eq "dry-run + input rc=0" "0" "$?"
expect_contains "dry-run 输出目标坐标" "目标坐标 (60,150)" "$out"
expect_contains "dry-run 声明未点击" "未点击" "$out"

out=$(bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" --json 2>&1)
expect_contains "dry-run --json 输出 center" '"center": [60, 150]' "$out"

# 非 clickable 目标在 JSON 模式下仍要输出可解析 JSON（⚠️ 不得混进 stdout）
out=$(bash "$TAP_SNAP" "Settings" --dry-run --input "$TMP/tap.json" --json 2>/dev/null)
expect_eq "非 clickable + --json rc=0" "0" "$?"
printf '%s\n' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.readline()); assert d["clickable"] is False' \
  && ok "--json stdout 未被 ⚠️ 污染" || bad "--json stdout 被 ⚠️ 污染"
out=$(bash "$TAP_SNAP" "Settings" --dry-run --input "$TMP/tap.json" --json 2>&1 1>/dev/null)
expect_contains "--json 的 ⚠️ 出现在 stderr" "clickable=false" "$out"

bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/nope.json" > /dev/null 2>&1
expect_eq "--input 文件不存在 rc=2" "2" "$?"
: > "$TMP/empty.json"
bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/empty.json" > /dev/null 2>&1
expect_eq "--input 空文件 rc=2（不落到取快照）" "2" "$?"
bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" --fresh > /dev/null 2>&1
expect_eq "--input 与 --fresh 互斥 rc=2" "2" "$?"
bash "$TAP_SNAP" "Add" --input "$TMP/tap.json" > /dev/null 2>&1
expect_eq "--input 非 dry-run 缺 --platform rc=2" "2" "$?"
bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" --index 0 > /dev/null 2>&1
expect_eq "tap --index 0 rc=2" "2" "$?"
bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" --max-age abc > /dev/null 2>&1
expect_eq "--max-age 非数字 rc=2" "2" "$?"
bash "$TAP_SNAP" --dry-run --input "$TMP/tap.json" > /dev/null 2>&1
expect_eq "缺目标文本 rc=2" "2" "$?"
bash "$TAP_SNAP" "a" "b" --dry-run --input "$TMP/tap.json" > /dev/null 2>&1
expect_eq "两个目标文本 rc=2" "2" "$?"
bash "$TAP_SNAP" "Add" --dry-run --input "$TMP/tap.json" --bogus > /dev/null 2>&1
expect_eq "未知参数 rc=2" "2" "$?"

out=$(bash "$TAP_SNAP" "zzz" --dry-run --input "$TMP/tap.json" 2>&1)
expect_eq "dry-run 未命中 rc=1" "1" "$?"
expect_contains "dry-run 未命中给候选" "候选: Settings" "$out"

# 坏 payload ⇒ rc=5 透传（不能被折成「未命中 1」）
printf 'not-json' > "$TMP/bad.json"
out=$(bash "$TAP_SNAP" "Add" --input "$TMP/bad.json" --platform android 2>&1)
expect_eq "坏 payload 透传 rc=5" "5" "$?"
expect_contains "坏 payload 提示不可解析" "不可解析" "$out"
bash "$TAP_SNAP" "Add" --input "$TMP/bad.json" --platform android --json > /dev/null 2>&1
expect_eq "坏 payload + --json rc=5" "5" "$?"
expect_eq "坏 payload + --json stdout 为空" "0" "$(bash "$TAP_SNAP" "Add" --input "$TMP/bad.json" --platform android --json 2>/dev/null | wc -c | tr -d ' ')"

# 命中但无 center ⇒ rc=6 透传
printf '{"dialect":"uiautomator","nodes":[{"type":"x","text":"noCenter","id":"","bounds":"","clickable":true,"center":null}]}' > "$TMP/nocenter.json"
bash "$TAP_SNAP" "noCenter" --input "$TMP/nocenter.json" --platform android > /dev/null 2>&1
expect_eq "无 center 透传 rc=6" "6" "$?"
bash "$TAP_SNAP" "noCenter" --input "$TMP/nocenter.json" --platform android --json > /dev/null 2>&1
expect_eq "无 center + --json rc=6" "6" "$?"

# ---------- tap_snapshot.sh：平台预检（不读缓存、不取快照） ----------
out=$(bash "$TAP_SNAP" "Sign In" --platform ios 2>&1)
expect_eq "platform ios rc=3" "3" "$?"
expect_contains "ios 指引 maestro/tap.sh" "maestro/tap.sh" "$out"

out=$(bash "$TAP_SNAP" "Sign In" --platform ios-device 2>&1)
expect_eq "platform ios-device rc=3" "3" "$?"
expect_contains "ios-device 说明不支持" "不支持 iOS 真机" "$out"
case "$out" in
  *"maestro/tap.sh"*) bad "ios-device 不应指引 maestro" ;;
  *) ok "ios-device 不指引 maestro" ;;
esac

bash "$TAP_SNAP" "x" --platform windows > /dev/null 2>&1
expect_eq "platform windows rc=3" "3" "$?"
bash "$TAP_SNAP" "x" --platform beos > /dev/null 2>&1
expect_eq "未知平台 rc=3" "3" "$?"

# ---------- tap_snapshot.sh：缓存行为 + 派发（SNAPSHOT_BIN / TAP_SNAPSHOT_DISPATCH 桩） ----------
CACHE_DIR="$TMP/log"; mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/last_snapshot.json"

write_cache_json() {  # write_cache_json <platform> <ts>
  python3 - "$CACHE_FILE" "$1" "$2" <<'PY'
import json, sys
path, platform, ts = sys.argv[1], sys.argv[2], int(sys.argv[3])
nodes = [
    {"type": "android.widget.TextView", "text": "Settings", "id": "",
     "bounds": "[0,0][400,800]", "clickable": False, "center": [200, 400]},
    {"type": "android.widget.TextView", "text": "Add", "id": "com.demo:id/add",
     "bounds": "[10,100][110,200]", "clickable": True, "center": [60, 150]},
]
json.dump({"dialect": "uiautomator", "fingerprint": "deadbeef", "raw_nodes": 2,
           "nodes": nodes, "_meta": {"platform": platform, "ts": ts}},
          open(path, "w", encoding="utf-8"))
PY
}

export STUB_LOG="$TMP/stub_calls.log"
export STUB_PAYLOAD="$TMP/stub_payload.json"
: > "$STUB_LOG"
python3 - "$STUB_PAYLOAD" <<'PY'
import json, sys
nodes = [
    {"type": "android.widget.TextView", "text": "Settings", "id": "",
     "bounds": "[0,0][400,800]", "clickable": False, "center": [200, 400]},
    {"type": "android.widget.TextView", "text": "Add", "id": "com.demo:id/add",
     "bounds": "[10,100][110,200]", "clickable": True, "center": [60, 150]},
]
json.dump({"dialect": "uiautomator", "fingerprint": "feedface", "raw_nodes": 2, "nodes": nodes},
          open(sys.argv[1], "w", encoding="utf-8"))
PY
cat > "$TMP/stub_snapshot.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
cat "$STUB_PAYLOAD"
SH
cat > "$TMP/stub_rc4.sh" <<'SH'
#!/bin/bash
exit 4
SH
cat > "$TMP/stub_rc1.sh" <<'SH'
#!/bin/bash
exit 1
SH
cat > "$TMP/dispatch_ok.sh" <<'SH'
#!/bin/bash
echo "$1 $2" > "$DISPATCH_LOG"
SH
chmod +x "$TMP/stub_snapshot.sh" "$TMP/stub_rc4.sh" "$TMP/stub_rc1.sh" "$TMP/dispatch_ok.sh"
export DISPATCH_LOG="$TMP/dispatch.log"

export LOG_DIR="$CACHE_DIR"
export SNAPSHOT_BIN="$TMP/stub_snapshot.sh"

# 新鲜缓存 ⇒ 复用，且不调 SNAPSHOT_BIN
write_cache_json android "$(date +%s)"
: > "$STUB_LOG"
out=$(bash "$TAP_SNAP" "Add" --dry-run --platform android 2>&1)
expect_eq "新鲜缓存 rc=0" "0" "$?"
expect_contains "新鲜缓存提示复用" "复用快照" "$out"
expect_eq "新鲜缓存不调 SNAPSHOT_BIN" "0" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# ts 过期 ⇒ 重新取快照
write_cache_json android "$(( $(date +%s) - 3600 ))"
: > "$STUB_LOG"
out=$(bash "$TAP_SNAP" "Add" --dry-run --platform android 2>&1)
case "$out" in
  *复用快照*) bad "过期缓存不应复用" ;;
  *) ok "过期缓存不复用" ;;
esac
expect_eq "过期后调用 SNAPSHOT_BIN" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# _meta.platform 不符 ⇒ 不读缓存
write_cache_json ios "$(date +%s)"
: > "$STUB_LOG"
bash "$TAP_SNAP" "Add" --dry-run --platform android > /dev/null 2>&1
expect_eq "平台不符则重取" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# --max-age 0 ⇒ 等价 --fresh
write_cache_json android "$(date +%s)"
: > "$STUB_LOG"
out=$(bash "$TAP_SNAP" "Add" --dry-run --platform android --max-age 0 2>&1)
case "$out" in
  *复用快照*) bad "--max-age 0 不应复用" ;;
  *) ok "--max-age 0 强制重取" ;;
esac
expect_eq "--max-age 0 调用 SNAPSHOT_BIN" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# --fresh ⇒ 强制重取
write_cache_json android "$(date +%s)"
: > "$STUB_LOG"
bash "$TAP_SNAP" "Add" --dry-run --platform android --fresh > /dev/null 2>&1
expect_eq "--fresh 强制重取" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"

# --dry-run 不删缓存
write_cache_json android "$(date +%s)"
bash "$TAP_SNAP" "Add" --dry-run --platform android > /dev/null 2>&1
if [ -f "$CACHE_FILE" ]; then ok "--dry-run 保留缓存"; else bad "--dry-run 不应删缓存"; fi

# snapshot rc 映射
rm -f "$CACHE_FILE"
out=$(SNAPSHOT_BIN="$TMP/stub_rc4.sh" bash "$TAP_SNAP" "Add" --platform android 2>&1)
expect_eq "snapshot rc=4 ⇒ tap rc=4" "4" "$?"
expect_contains "语义树为空提示" "语义树为空" "$out"
out=$(SNAPSHOT_BIN="$TMP/stub_rc1.sh" bash "$TAP_SNAP" "Add" --platform android 2>&1)
expect_eq "snapshot rc=1 ⇒ tap rc=5" "5" "$?"
expect_contains "快照失败提示" "快照失败" "$out"
expect_contains "快照失败附带 rc=1" "snapshot rc=1" "$out"
cat > "$TMP/stub_rc2.sh" <<'SH'
#!/bin/bash
echo "模拟 dump 失败" >&2
exit 2
SH
chmod +x "$TMP/stub_rc2.sh"
out=$(SNAPSHOT_BIN="$TMP/stub_rc2.sh" bash "$TAP_SNAP" "Add" --platform android 2>&1)
expect_eq "snapshot rc=2 ⇒ tap rc=5" "5" "$?"
expect_contains "未知 rc 提示原始码" "snapshot rc=2" "$out"
expect_contains "未知 rc 附带 stderr 末行" "模拟 dump 失败" "$out"

# 派发失败 ⇒ rc=7 且缓存保留
write_cache_json android "$(date +%s)"
out=$(TAP_SNAPSHOT_DISPATCH=false bash "$TAP_SNAP" "Add" --platform android 2>&1)
expect_eq "派发失败 rc=7" "7" "$?"
expect_contains "派发失败提示" "点击派发失败" "$out"
if [ -f "$CACHE_FILE" ]; then ok "派发失败保留缓存"; else bad "派发失败不应删缓存"; fi

# 派发成功 ⇒ rc=0、坐标正确、last 轮转为 prev（H1-c：成功即轮转，不再删除）
write_cache_json android "$(date +%s)"
rm -f "$DISPATCH_LOG" "$CACHE_DIR/prev_snapshot.json"
out=$(TAP_SNAPSHOT_DISPATCH="$TMP/dispatch_ok.sh" bash "$TAP_SNAP" "Add" --platform android 2>&1)
expect_eq "派发成功 rc=0" "0" "$?"
expect_eq "派发坐标 = 命中中心" "60 150" "$(cat "$DISPATCH_LOG")"
expect_contains "点击完成提示" "点击完成" "$out"
if [ -f "$CACHE_FILE" ]; then bad "成功后 last 应失效（轮转为 prev）"; else ok "成功后 last 轮转"; fi
expect_eq "prev == 点击前快照" "deadbeef" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fingerprint"])' "$CACHE_DIR/prev_snapshot.json" 2>/dev/null)"

# --keep-cache ⇒ last 与 prev 都不动
write_cache_json android "$(date +%s)"
rm -f "$CACHE_DIR/prev_snapshot.json"
TAP_SNAPSHOT_DISPATCH="$TMP/dispatch_ok.sh" bash "$TAP_SNAP" "Add" --platform android --keep-cache > /dev/null 2>&1
if [ -f "$CACHE_FILE" ]; then ok "--keep-cache 保留缓存"; else bad "--keep-cache 应保留缓存"; fi
if [ -f "$CACHE_DIR/prev_snapshot.json" ]; then bad "--keep-cache 不应轮转"; else ok "--keep-cache 不轮转"; fi

# 只读保证：last 缺失但 prev 存在 ⇒ 不得复用 prev 的坐标（应重新取快照）
write_cache_json android "$(date +%s)"
mv -f "$CACHE_FILE" "$CACHE_DIR/prev_snapshot.json"
: > "$STUB_LOG"
bash "$TAP_SNAP" "Add" --dry-run --platform android > /dev/null 2>&1
expect_eq "prev 不作坐标源（重新取快照）" "1" "$(wc -l < "$STUB_LOG" | tr -d ' ')"
rm -f "$CACHE_DIR/prev_snapshot.json"

unset LOG_DIR SNAPSHOT_BIN STUB_LOG STUB_PAYLOAD DISPATCH_LOG

# ---------- 平台自动判定（_platform_detect.sh，snapshot.sh / tap_snapshot.sh 共用） ----------
DETECT="$SCRIPT_DIR/_platform_detect.sh"
mkdir -p "$TMP/bin_android" "$TMP/bin_ios" "$TMP/bin_none"
cat > "$TMP/bin_android/adb" <<'SH'
#!/bin/bash
[ "$1" = "devices" ] && { echo "List of devices attached"; echo "FAKE123	device"; }
SH
cat > "$TMP/bin_ios/adb" <<'SH'
#!/bin/bash
[ "$1" = "devices" ] && echo "List of devices attached"
SH
cat > "$TMP/bin_ios/xcrun" <<'SH'
#!/bin/bash
echo "    iPhone 17e (UUID) (Booted)"
SH
chmod +x "$TMP/bin_android/adb" "$TMP/bin_ios/adb" "$TMP/bin_ios/xcrun"
expect_eq "detect_platform: 有 Android 设备 ⇒ android" "android" \
  "$(PATH="$TMP/bin_android:$PATH" bash -c "source '$DETECT'; detect_platform")"
expect_eq "detect_platform: 无 Android 设备但有 iOS 模拟器 ⇒ ios" "ios" \
  "$(PATH="$TMP/bin_ios:$PATH" bash -c "source '$DETECT'; detect_platform")"
PATH="$TMP/bin_none" /bin/bash -c "source '$DETECT'; detect_platform" > /dev/null 2>&1
expect_eq "detect_platform: 两者皆无 ⇒ rc=1" "1" "$?"
# 共用性：两个入口脚本都不得再自带一份 detect_platform 定义
expect_eq "snapshot.sh 不再内联 detect_platform" "0" "$(grep -c '^detect_platform()' "$SCRIPT_DIR/snapshot.sh")"
expect_eq "tap_snapshot.sh 不再内联 detect_platform" "0" "$(grep -c '^detect_platform()' "$SCRIPT_DIR/tap_snapshot.sh")"

# ---------- _snapshot_diff.py：配对 / 分类 / 排序 / 截断（纯离线） ----------
DIFF="$SCRIPT_DIR/_snapshot_diff.py"
TAB=$'\t'

cat > "$TMP/dn_a.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":7,"fingerprint":"aaaa1111","nodes":[
 {"type":"T","text":"Title","id":"app:id/title","bounds":"[0,0][100,20]","clickable":false},
 {"type":"T","text":"08:30","id":"","bounds":"[0,100][50,120]","clickable":false},
 {"type":"B","text":"Play","id":"","bounds":"[10,200][60,240]","clickable":true},
 {"type":"B","text":"Play","id":"","bounds":"[10,300][60,340]","clickable":true},
 {"type":"V","text":"Loading","id":"","bounds":"[0,400][100,440]","clickable":false},
 {"type":"V","text":"Smart","id":"","bounds":"[0,500][100,540]","clickable":true},
 {"type":"V","text":"Ghost","id":"","bounds":"","clickable":false}
]}
JSON
cat > "$TMP/dn_b.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":7,"fingerprint":"bbbb2222","nodes":[
 {"type":"T","text":"Title2","id":"app:id/title","bounds":"[0,0][100,20]","clickable":false},
 {"type":"T","text":"08:31","id":"","bounds":"[0,100][50,120]","clickable":false},
 {"type":"B","text":"Play","id":"","bounds":"[10,202][60,242]","clickable":true},
 {"type":"B","text":"Play","id":"","bounds":"[10,300][60,340]","clickable":true},
 {"type":"V","text":"Smart","id":"","bounds":"[0,500][100,540]","clickable":false},
 {"type":"B","text":"Add","id":"app:id/add","bounds":"[0,600][100,640]","clickable":true},
 {"type":"V","text":"Ghost2","id":"","bounds":"","clickable":false}
]}
JSON

out=$(python3 "$DIFF" --baseline "$TMP/dn_a.json" --current "$TMP/dn_b.json" --baseline-kind last --baseline-age 12)
expect_eq "diff rc=0" "0" "$?"
expect_contains "diff header 计数（截断前全量）" "+2 -2 ~3 (text 2 / pos 0 / clickable 1)" "$out"
expect_contains "diff header 带 fp 与 nodes" "fp=aaaa1111→bbbb2222 nodes=7" "$out"
expect_contains "diff header 带 baseline 标签" "baseline=last(age=12s)" "$out"
expect_eq "diff 行数 = header + 7" "8" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_contains "~ text 行（id 配对，text+bounds 变只报 text）" \
  "~ text${TAB}T${TAB}Title→Title2${TAB}app:id/title" "$out"
expect_contains "~ text 行（bounds 配对：时间戳刷新）" "~ text${TAB}T${TAB}08:30→08:31" "$out"
expect_contains "~ clickable 行" \
  "~ clickable${TAB}V${TAB}Smart${TAB}${TAB}[0,500][100,540]${TAB}true→false" "$out"
expect_contains "+ 行（新增节点）" "+${TAB}B${TAB}Add${TAB}app:id/add${TAB}[0,600][100,640]" "$out"
expect_contains "- 行（消失节点）" "-${TAB}V${TAB}Loading${TAB}${TAB}[0,400][100,440]" "$out"
expect_eq "2px 抖动不算 ~pos" "0" "$(printf '%s\n' "$out" | grep -c '~ pos' || true)"
expect_eq "多重集：两个 Play 不误判为 +/-" "0" "$(printf '%s\n' "$out" | grep -cE '^[+-]	B	Play' || true)"
expect_eq "bounds 不可解析者不参与配对（Ghost 只作 +/-）" "2" \
  "$(printf '%s\n' "$out" | grep -cE '^[+-]	V	Ghost' || true)"

# 同一节点多类同变 ⇒ 只报 1 行，且优先报 text
cat > "$TMP/mc_a.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"11111111","nodes":[
 {"type":"T","text":"A","id":"app:id/x","bounds":"[0,0][10,10]","clickable":true}]}
JSON
cat > "$TMP/mc_b.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"22222222","nodes":[
 {"type":"T","text":"B","id":"app:id/x","bounds":"[0,0][30,30]","clickable":false}]}
JSON
out=$(python3 "$DIFF" --baseline "$TMP/mc_a.json" --current "$TMP/mc_b.json")
expect_eq "多类同变只报 1 行" "1" "$(printf '%s\n' "$out" | grep -c '^~' || true)"
expect_contains "多类同变优先报 text" "~ text" "$out"

# 阈值：3px ⇒ ~pos（2px 不算，见上）
cat > "$TMP/th_a.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"33333333","nodes":[
 {"type":"T","text":"A","id":"","bounds":"[0,0][10,10]","clickable":false}]}
JSON
cat > "$TMP/th_b.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"44444444","nodes":[
 {"type":"T","text":"A","id":"","bounds":"[0,0][13,10]","clickable":false}]}
JSON
out=$(python3 "$DIFF" --baseline "$TMP/th_a.json" --current "$TMP/th_b.json")
expect_contains "3px 判为 ~pos" "~ pos" "$out"

# 完全相同的两份 ⇒ header 全零、只有 header 一行
out=$(python3 "$DIFF" --baseline "$TMP/dn_a.json" --current "$TMP/dn_a.json")
expect_contains "无变化 header 全零" "+0 -0 ~0 (text 0 / pos 0 / clickable 0)" "$out"
expect_eq "无变化只有 header 一行" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

# 截断：--max-diff 2 ⇒ 2 行 + 「另有 N 项」（N = 总数 − 显示数）
out=$(python3 "$DIFF" --baseline "$TMP/dn_a.json" --current "$TMP/dn_b.json" --max-diff 2)
expect_eq "截断后行数 = header + 2 + 提示" "4" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_contains "截断提示 N 准确" "另有 5 项未显示（共 7 项变化" "$out"

python3 "$DIFF" --baseline "$TMP/dn_a.json" --current "$TMP/dn_b.json" --max-diff 0 > /dev/null 2>&1
expect_eq "diff --max-diff 0 rc=2" "2" "$?"
python3 "$DIFF" --baseline "$TMP/dn_a.json" > /dev/null 2>&1
expect_eq "diff 缺 --current rc=2" "2" "$?"

# ---------- snapshot.sh --diff：基线解析 / 校验 / 写缓存 / SNAPSHOT_INPUT 钩子 ----------
SNAP="$SCRIPT_DIR/snapshot.sh"
DIFF_DIR="$TMP/diff_log"; mkdir -p "$DIFF_DIR"
LAST="$DIFF_DIR/last_snapshot.json"
PREV="$DIFF_DIR/prev_snapshot.json"

cat > "$TMP/d1.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node class="T" text="Title" resource-id="app:id/title" clickable="false" bounds="[0,0][100,20]"/>
  <node class="T" text="08:30" resource-id="" clickable="false" bounds="[0,100][50,120]"/>
  <node class="B" text="Play" resource-id="" clickable="true" bounds="[10,200][60,240]"/>
  <node class="B" text="Play" resource-id="" clickable="true" bounds="[10,300][60,340]"/>
  <node class="V" text="Loading" resource-id="" clickable="false" bounds="[0,400][100,440]"/>
  <node class="V" text="Smart" resource-id="" clickable="true" bounds="[0,500][100,540]"/>
  <node class="V" text="Ghost" resource-id="" clickable="false" bounds=""/>
</hierarchy>
XML
cat > "$TMP/d2.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node class="T" text="Title2" resource-id="app:id/title" clickable="false" bounds="[0,0][100,20]"/>
  <node class="T" text="08:31" resource-id="" clickable="false" bounds="[0,100][50,120]"/>
  <node class="B" text="Play" resource-id="" clickable="true" bounds="[10,202][60,242]"/>
  <node class="B" text="Play" resource-id="" clickable="true" bounds="[10,300][60,340]"/>
  <node class="V" text="Smart" resource-id="" clickable="false" bounds="[0,500][100,540]"/>
  <node class="B" text="Add" resource-id="app:id/add" clickable="true" bounds="[0,600][100,640]"/>
  <node class="V" text="Ghost2" resource-id="" clickable="false" bounds=""/>
</hierarchy>
XML

snap() { LOG_DIR="$DIFF_DIR" SNAPSHOT_INPUT="$1" bash "$SNAP" --platform android "${@:2}"; }
fp_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fingerprint"])' "$1" 2>/dev/null; }
write_meta_payload() {  # write_meta_payload <path> <dialect> <platform> <ts>
  python3 - "$@" <<'PY'
import json, sys
path, dialect, platform, ts = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
nodes = [{"type": "android.widget.TextView", "text": "Home", "id": "com.demo:id/home",
          "bounds": "[0,0][100,100]", "clickable": False}]
json.dump({"dialect": dialect, "fingerprint": "cafe0000", "raw_nodes": 1, "nodes": nodes,
           "_meta": {"platform": platform, "ts": ts}}, open(path, "w", encoding="utf-8"))
PY
}

# 无基线 ⇒ rc=1，但本次观测已落缓存（P1-2：避免自愈多烧 1–2 次 dump）
rm -f "$LAST" "$PREV"
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "无基线 --diff rc=1" "1" "$?"
expect_contains "无基线提示基线已建立" "基线已建立" "$out"
if [ -f "$LAST" ]; then ok "无基线时本次观测已落盘"; else bad "无基线时应落盘（否则自愈多烧 dump）"; fi

# 同页 ⇒ +0 -0 ~0，基线取 last
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "同页 --diff rc=0" "0" "$?"
expect_contains "同页 header 全零" "+0 -0 ~0" "$out"
expect_contains "同页基线为 last" "baseline=last(" "$out"
cp "$LAST" "$TMP/d1_saved.json"

# 变化页 ⇒ 计数正确、write_cache 把旧 last 轮转为 prev
out=$(snap "$TMP/d2.xml" --diff 2>&1)
expect_eq "变化页 --diff rc=0" "0" "$?"
expect_contains "变化页计数" "+2 -2 ~3 (text 2 / pos 0 / clickable 1)" "$out"
expect_contains "变化页 nodes=7" "nodes=7" "$out"
case "$out" in *"# dialect="*) bad "--diff 不应打印摘要" ;; *) ok "--diff 取代摘要输出" ;; esac
if [ -f "$PREV" ]; then ok "write_cache 轮转生成 prev"; else bad "write_cache 未生成 prev"; fi
expect_eq "prev == 旧 last" "$(fp_of "$TMP/d1_saved.json")" "$(fp_of "$PREV")"

# --against 显式基线优先于 last
out=$(snap "$TMP/d2.xml" --diff --against "$TMP/d1_saved.json" 2>&1)
expect_eq "--against rc=0" "0" "$?"
expect_contains "--against 计数同 last 基线" "+2 -2 ~3" "$out"
expect_contains "--against header 标文件名" "baseline=file:d1_saved.json(" "$out"

# --against 缺文件 rc=2；坏 JSON / XML / 缺键 rc=1（不静默回退 last）
snap "$TMP/d2.xml" --diff --against "$TMP/nope.json" > /dev/null 2>&1
expect_eq "--against 缺文件 rc=2" "2" "$?"
printf 'not json' > "$TMP/bad.json"
snap "$TMP/d2.xml" --diff --against "$TMP/bad.json" > /dev/null 2>&1
expect_eq "--against 坏 JSON rc=1" "1" "$?"
snap "$TMP/d2.xml" --diff --against "$TMP/d1.xml" > /dev/null 2>&1
expect_eq "--against 指 XML rc=1" "1" "$?"
printf '{}' > "$TMP/empty.json"
snap "$TMP/d2.xml" --diff --against "$TMP/empty.json" > /dev/null 2>&1
expect_eq "--against {} 缺键 rc=1" "1" "$?"

# 只有 prev ⇒ header 标 baseline=prev
rm -f "$LAST"
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "只有 prev 时 rc=0" "0" "$?"
expect_contains "只有 prev 时 header 标 prev" "baseline=prev(" "$out"

# 隐式基线 dialect/platform 不符 ⇒ rc=1 且**不降级读 prev**
write_meta_payload "$PREV" uiautomator android "$(date +%s)"
write_meta_payload "$LAST" maestro ios "$(date +%s)"
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "隐式基线不符 rc=1" "1" "$?"
expect_contains "隐式基线不符提示已跳过" "已跳过" "$out"
case "$out" in *baseline=prev*) bad "隐式基线不符不应降级读 prev" ;; *) ok "隐式基线不符不降级读 prev" ;; esac

# 隐式基线仅 platform 不符（dialect 相同）同样硬拒
write_meta_payload "$PREV" uiautomator android "$(date +%s)"
write_meta_payload "$LAST" uiautomator ios "$(date +%s)"
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "隐式基线仅 platform 不符 rc=1" "1" "$?"
expect_contains "仅 platform 不符提示" "platform ios≠android" "$out"

# 显式 --against 跨方言 ⇒ 只 ⚠️、仍输出（显式=用户责任）
write_meta_payload "$TMP/ios.json" maestro ios "$(date +%s)"
out=$(snap "$TMP/d1.xml" --diff --against "$TMP/ios.json" 2>&1)
expect_eq "显式跨方言基线仍 rc=0" "0" "$?"
expect_contains "显式跨方言基线打 ⚠️" "基线平台/方言不一致" "$out"

# --diff --no-cache：仍读基线、不写新缓存、不轮转
rm -f "$LAST" "$PREV"
snap "$TMP/d1.xml" > /dev/null 2>&1
fp_before=$(fp_of "$LAST")
snap "$TMP/d2.xml" --diff --no-cache > /dev/null 2>&1
expect_eq "--diff --no-cache rc=0" "0" "$?"
expect_eq "--no-cache 不写新缓存" "$fp_before" "$(fp_of "$LAST")"
if [ -f "$PREV" ]; then bad "--no-cache 不应轮转"; else ok "--no-cache 不轮转"; fi

# 基线 age > 60s ⇒ header 标 stale + 💡（不阻断）
write_meta_payload "$LAST" uiautomator android "$(( $(date +%s) - 300 ))"
rm -f "$PREV"
out=$(snap "$TMP/d1.xml" --diff 2>&1)
expect_eq "旧基线仍 rc=0" "0" "$?"
expect_contains "旧基线 header 标 stale" "stale" "$out"
expect_contains "旧基线提示改用 --against" "基线较旧" "$out"

# 参数矩阵
snap "$TMP/d1.xml" --diff --json > /dev/null 2>&1
expect_eq "--diff --json rc=2" "2" "$?"
snap "$TMP/d1.xml" --diff --max-diff 0 > /dev/null 2>&1
expect_eq "--diff --max-diff 0 rc=2" "2" "$?"
snap "$TMP/d1.xml" --diff --max-diff abc > /dev/null 2>&1
expect_eq "--diff --max-diff abc rc=2" "2" "$?"
snap "$TMP/d1.xml" --against "$TMP/d1_saved.json" > /dev/null 2>&1
expect_eq "--against 无 --diff rc=2" "2" "$?"
snap "$TMP/d1.xml" --max-diff 5 > /dev/null 2>&1
expect_eq "--max-diff 无 --diff rc=2" "2" "$?"

# snapshot --diff 的截断（d1 → d2 共 7 项变化）
snap "$TMP/d1.xml" > /dev/null 2>&1
out=$(snap "$TMP/d2.xml" --diff --max-diff 2 2>&1)
expect_contains "snapshot --diff 截断提示" "另有 5 项未显示" "$out"
expect_eq "snapshot --diff 截断行数" "4" "$(printf '%s\n' "$out" | grep -cE '^(#|\+|-|~ |另有)' || true)"

# 钩子契约：文件不存在 rc=2；平台契约不因钩子放宽
snap "$TMP/nope.xml" > /dev/null 2>&1
expect_eq "SNAPSHOT_INPUT 缺文件 rc=2" "2" "$?"
LOG_DIR="$DIFF_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform windows > /dev/null 2>&1
expect_eq "windows rc=3（钩子不放宽平台契约）" "3" "$?"

# --diff --no-cache 且无基线：rc=1 但**不谎报**「基线已建立」（未落盘）
rm -f "$LAST" "$PREV"
out=$(snap "$TMP/d1.xml" --diff --no-cache 2>&1)
expect_eq "--diff --no-cache 无基线 rc=1" "1" "$?"
case "$out" in *基线已建立*) bad "--no-cache 未落盘却提示基线已建立" ;; *) ok "--no-cache 不谎报基线已建立" ;; esac
if [ -f "$LAST" ]; then bad "--no-cache 无基线时不应落盘"; else ok "--no-cache 无基线时不落盘"; fi

# ---------- _tap_target.py：未命中建议按 dialect 分支（H2） ----------
TARGET="$SCRIPT_DIR/_tap_target.py"
cat > "$TMP/tg_android.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"aaaa","nodes":[
 {"type":"T","text":"Home","id":"","bounds":"[0,0][10,10]","clickable":true}]}
JSON
cat > "$TMP/tg_ios.json" <<'JSON'
{"dialect":"maestro","raw_nodes":1,"fingerprint":"bbbb","nodes":[
 {"type":"node","text":"Home","id":"","bounds":"[0,0][10,10]","clickable":true}]}
JSON
out=$(python3 "$TARGET" --text "Settings" < "$TMP/tg_android.json" 2>&1)
expect_eq "uiautomator 未命中 rc=1" "1" "$?"
expect_contains "uiautomator 建议 findtap" "android/findtap.sh" "$out"
case "$out" in *maestro/tap.sh*) bad "uiautomator 不应建议 maestro" ;; *) ok "uiautomator 不推 maestro" ;; esac
out=$(python3 "$TARGET" --text "Settings" < "$TMP/tg_ios.json" 2>&1)
expect_eq "maestro 未命中 rc=1" "1" "$?"
expect_contains "maestro 建议 maestro/tap.sh" "maestro/tap.sh" "$out"
case "$out" in *findtap.sh*) bad "maestro 不应建议 findtap" ;; *) ok "maestro 不推 findtap" ;; esac

# 语义树为空（nodes=0）⇒ 不推滚动查找，改提示语义树为空
cat > "$TMP/tg_empty.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"cccc","nodes":[]}
JSON
out=$(python3 "$TARGET" --text "Settings" < "$TMP/tg_empty.json" 2>&1)
expect_eq "空语义树未命中 rc=1" "1" "$?"
expect_contains "空语义树提示语义树为空" "语义树为空" "$out"
case "$out" in *"目标可能在屏外"*) bad "空语义树不应推滚动查找" ;; *) ok "空语义树不推滚动查找" ;; esac

# ---------- _snapshot_diff.py：--strict / 自动 age / --check-payload ----------
cat > "$TMP/dn_cur.json" <<'JSON'
{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"dddd","nodes":[
 {"type":"T","text":"Home","id":"","bounds":"[0,0][10,10]","clickable":false}]}
JSON
write_meta_payload "$TMP/dn_ok.json" uiautomator android "$(date +%s)"
write_meta_payload "$TMP/dn_ios.json" uiautomator ios "$(date +%s)"
write_meta_payload "$TMP/dn_maestro.json" maestro android "$(date +%s)"

python3 "$DIFF" --baseline "$TMP/dn_ok.json" --current "$TMP/dn_cur.json" --baseline-kind prev --strict --platform android > "$TMP/dn_out.txt" 2>/dev/null
expect_eq "strict 一致 rc=0" "0" "$?"
expect_contains "strict 一致输出 header" "# diff" "$(cat "$TMP/dn_out.txt")"
expect_contains "自动 age（kind=prev 且未给 --baseline-age）" "baseline=prev(age=" "$(head -1 "$TMP/dn_out.txt")"

python3 "$DIFF" --baseline "$TMP/dn_ios.json" --current "$TMP/dn_cur.json" --baseline-kind prev --strict --platform android > "$TMP/dn_out.txt" 2>"$TMP/dn_err.txt"
expect_eq "strict platform 不符 rc=1" "1" "$?"
expect_eq "strict 不符不输出 diff" "0" "$(wc -c < "$TMP/dn_out.txt" | tr -d ' ')"
expect_contains "strict 不符提示原因" "platform ios≠android" "$(cat "$TMP/dn_err.txt")"

python3 "$DIFF" --baseline "$TMP/dn_maestro.json" --current "$TMP/dn_cur.json" --baseline-kind prev --strict > /dev/null 2>&1
expect_eq "strict dialect 不符 rc=1" "1" "$?"

python3 "$DIFF" --check-payload "$TMP/dn_cur.json" > /dev/null 2>&1
expect_eq "--check-payload 可用 rc=0" "0" "$?"
python3 "$DIFF" --check-payload "$TMP/d1.xml" > /dev/null 2>&1
expect_eq "--check-payload 非 --json 产物 rc=1" "1" "$?"
python3 "$DIFF" --check-payload "$TMP/nope.json" > /dev/null 2>&1
expect_eq "--check-payload 文件不存在 rc=2" "2" "$?"

# ---------- snapshot.sh：--single-dump 参数面 ----------
LOG_DIR="$DIFF_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform ios --single-dump --json > /dev/null 2>"$TMP/sd_err.txt"
expect_eq "--single-dump 在 ios 不影响 rc" "0" "$?"
expect_contains "--single-dump 在 ios 打 ⚠️" "仅 Android 生效" "$(cat "$TMP/sd_err.txt")"
LOG_DIR="$DIFF_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform android --single-dump --wait-stable > /dev/null 2>&1
expect_eq "--single-dump × --wait-stable rc=2" "2" "$?"
LOG_DIR="$DIFF_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform android --single-dump --json > /dev/null 2>&1
expect_eq "SNAPSHOT_INPUT 下 --single-dump 被忽略（rc=0）" "0" "$?"
snap "$TMP/d1.xml" > /dev/null 2>&1
snap "$TMP/d1.xml" --single-dump --diff > /dev/null 2>&1
expect_eq "--single-dump × --diff 允许" "0" "$?"

# ---------- snapshot.sh：--cache-payload ----------
CP_DIR="$TMP/cp_log"; mkdir -p "$CP_DIR"
rm -f "$CP_DIR/last_snapshot.json" "$CP_DIR/prev_snapshot.json"
LOG_DIR="$CP_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform android --json > /dev/null 2>&1
cp "$CP_DIR/last_snapshot.json" "$TMP/cp_first.json"
out=$(LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --platform android 2>&1)
expect_eq "--cache-payload rc=0" "0" "$?"
expect_contains "--cache-payload 落盘提示" "已落盘" "$out"
expect_eq "--cache-payload 写入 _meta.platform" "android" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["_meta"]["platform"])' "$CP_DIR/last_snapshot.json")"
expect_eq "--cache-payload 新载荷成为 last" "dddd" "$(fp_of "$CP_DIR/last_snapshot.json")"
expect_eq "--cache-payload 旧 last 轮转为 prev" "$(fp_of "$TMP/cp_first.json")" "$(fp_of "$CP_DIR/prev_snapshot.json")"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/d1.xml" > /dev/null 2>&1
expect_eq "--cache-payload 非 --json 产物 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/nope.json" > /dev/null 2>&1
expect_eq "--cache-payload 文件不存在 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --json > /dev/null 2>&1
expect_eq "--cache-payload + --json 互斥 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --no-cache > /dev/null 2>&1
expect_eq "--cache-payload + --no-cache 互斥 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --diff > /dev/null 2>&1
expect_eq "--cache-payload + --diff 互斥 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --against "" > /dev/null 2>&1
expect_eq "--cache-payload + --against 空值 互斥 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/dn_cur.json" --max 5 > /dev/null 2>&1
expect_eq "--cache-payload + --max 互斥 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "" > /dev/null 2>&1
expect_eq "--cache-payload 空值 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/tg_ios.json" --platform android > /dev/null 2>&1
expect_eq "--cache-payload 方言与平台不自洽 rc=2" "2" "$?"
LOG_DIR="$CP_DIR" bash "$SNAP" --cache-payload "$TMP/tg_ios.json" --platform ios > /dev/null 2>&1
expect_eq "--cache-payload maestro↔ios 允许" "0" "$?"
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for tool in python3 cat mkdir mv rm dirname; do
  src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$MINBIN/$tool"
done
env PATH="$MINBIN" LOG_DIR="$CP_DIR" /bin/bash "$SNAP" --cache-payload "$TMP/dn_cur.json" > /dev/null 2>&1
expect_eq "--cache-payload 平台不可判定 rc=3" "3" "$?"

# ---------- assert_page.sh：H1 失败附 diff ----------
AP="$SCRIPT_DIR/assert_page.sh"
H1_DIR="$TMP/ap_log"; mkdir -p "$H1_DIR"
H1_LAST="$H1_DIR/last_snapshot.json"; H1_PREV="$H1_DIR/prev_snapshot.json"
ap() { LOG_DIR="$H1_DIR" SNAPSHOT_INPUT="$1" bash "$AP" --platform android "${@:2}"; }

ap "$TMP/d1.xml" --has "Loading" > /dev/null 2>&1
expect_eq "assert_page 通过 rc=0" "0" "$?"
out=$(ap "$TMP/d2.xml" --has "Loading" 2>"$TMP/ap_err.txt")
expect_eq "断言失败 rc=1" "1" "$?"
expect_contains "失败 stdout 仍是 FAIL 行" "❌ 1/1 FAIL" "$out"
case "$out" in *"与上一份快照的差异"*) bad "diff 不应写 stdout" ;; *) ok "diff 不污染 stdout" ;; esac
err=$(cat "$TMP/ap_err.txt")
expect_contains "stderr 含 diff 标题" "与上一份快照的差异" "$err"
expect_contains "stderr 基线为 prev 且带 age" "baseline=prev(age=" "$err"
if printf '%s\n' "$err" | grep -q $'^-\t.*Loading'; then ok "stderr 含被删节点行（-…Loading）"; else bad "stderr 缺少被删节点行（-…Loading）"; fi
expect_contains "stderr 含新增节点（Add）" "Add" "$err"

ap "$TMP/d2.xml" --has "Loading" --no-diff > /dev/null 2>"$TMP/ap_err.txt"
expect_eq "--no-diff 仍 rc=1" "1" "$?"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "--no-diff 仍输出 diff" ;; *) ok "--no-diff 不输出 diff" ;; esac

rm -f "$H1_LAST" "$H1_PREV"
ap "$TMP/d2.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
expect_eq "无 prev 时 rc=1" "1" "$?"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "无 prev 不应输出 diff" ;; *) ok "无 prev 静默跳过 diff" ;; esac

rm -f "$H1_LAST"
write_meta_payload "$H1_PREV" uiautomator ios "$(date +%s)"
ap "$TMP/d2.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "platform 不符不应输出 diff" ;; *) ok "prev platform 不符时静默跳过" ;; esac

rm -f "$H1_LAST"
write_meta_payload "$H1_PREV" maestro android "$(date +%s)"
ap "$TMP/d2.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "dialect 不符不应输出 diff" ;; *) ok "prev dialect 不符时静默跳过" ;; esac

rm -f "$H1_LAST"
write_meta_payload "$H1_PREV" uiautomator android "$(( $(date +%s) - 600 ))"
ap "$TMP/d2.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
expect_contains "prev 过旧仍输出并标 stale" "stale" "$(cat "$TMP/ap_err.txt")"

cat > "$TMP/empty.xml" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node class="android.widget.FrameLayout" text="" resource-id="" clickable="false" bounds="[0,0][100,100]"/>
</hierarchy>
XML
ap "$TMP/d1.xml" > /dev/null 2>&1
ap "$TMP/empty.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
expect_eq "空树 rc=4" "4" "$?"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "rc=4 不应附 diff（会误导为全删）" ;; *) ok "rc=4 不附 diff" ;; esac

printf '<hierarchy><node' > "$TMP/broken.xml"
ap "$TMP/broken.xml" --has "Loading" > /dev/null 2>"$TMP/ap_err.txt"
expect_eq "解析失败 rc=5" "5" "$?"
case "$(cat "$TMP/ap_err.txt")" in *"与上一份快照的差异"*) bad "rc=5 不应附 diff" ;; *) ok "rc=5 不附 diff" ;; esac

# ios-device：方言反推为 ios，不得覆盖权威平台（否则 --strict 恒不符 ⇒ H1 静默失效）
IOSD_DIR="$TMP/iosd_log"; mkdir -p "$IOSD_DIR"
cat > "$TMP/xcui2.xml" <<'XML'
<AppiumAUT>
  <XCUIElementTypeApplication name="Demo" label="Demo" x="0" y="0" width="390" height="844">
    <XCUIElementTypeStaticText name="title" label="设置页" value="" x="16" y="50" width="200" height="20"/>
  </XCUIElementTypeApplication>
</AppiumAUT>
XML
LOG_DIR="$IOSD_DIR" SNAPSHOT_INPUT="$TMP/xcui.xml" bash "$SNAP" --platform ios-device --json > /dev/null 2>&1
LOG_DIR="$IOSD_DIR" SNAPSHOT_INPUT="$TMP/xcui2.xml" bash "$AP" --platform ios-device --has "订单列表" > /dev/null 2>"$TMP/iosd_err.txt"
expect_eq "ios-device 断言失败 rc=1" "1" "$?"
expect_contains "ios-device 仍能附 diff（平台不被方言覆盖）" "与上一份快照的差异" "$(cat "$TMP/iosd_err.txt")"

# ---------- assert_page.sh：--wait 轮询（SNAPSHOT_BIN 桩序列） ----------
H2_DIR="$TMP/h2_log"; SEQ_DIR="$TMP/h2_seq"; mkdir -p "$H2_DIR" "$SEQ_DIR"
python3 "$PARSE" --input "$TMP/d1.xml" --json > "$SEQ_DIR/pass.json"
python3 "$PARSE" --input "$TMP/d2.xml" --json > "$SEQ_DIR/fail.json"
cat > "$TMP/stub_seq.sh" <<'SH'
idx=0
[ -f "$SEQ_DIR/count" ] && idx=$(cat "$SEQ_DIR/count")
printf '%s\n' $((idx + 1)) > "$SEQ_DIR/count"
IFS=',' read -ra parts <<< "$SEQ"
n=${#parts[@]}
[ "$idx" -ge "$n" ] && idx=$((n - 1))
case "${parts[$idx]}" in
  pass) cat "$SEQ_DIR/pass.json"; exit 0 ;;
  fail) cat "$SEQ_DIR/fail.json"; exit 0 ;;
  4)    printf '%s' '{"dialect":"uiautomator","raw_nodes":1,"fingerprint":"e0","nodes":[]}'; exit 4 ;;
  3)    exit 3 ;;
  *)    exit 1 ;;
esac
SH
h2() {  # h2 <序列> [额外参数...]
  rm -f "$SEQ_DIR/count"
  SEQ="$1" SEQ_DIR="$SEQ_DIR" LOG_DIR="$H2_DIR" SNAPSHOT_BIN="$TMP/stub_seq.sh" \
    bash "$AP" --platform android --has "Loading" "${@:2}"
}

rm -f "$H2_DIR/last_snapshot.json" "$H2_DIR/prev_snapshot.json"
out=$(h2 "fail,fail,pass" --wait 10 2>/dev/null)
expect_eq "H2 第 3 次通过 rc=0" "0" "$?"
expect_contains "H2 通过输出轮询次数" "第 3 次" "$out"
expect_eq "H2 通过后 last = 最后一次 payload" "$(fp_of "$SEQ_DIR/pass.json")" "$(fp_of "$H2_DIR/last_snapshot.json")"
expect_eq "H2 通过后 _meta.platform" "android" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["_meta"]["platform"])' "$H2_DIR/last_snapshot.json")"

rm -f "$H2_DIR/last_snapshot.json"
out=$(h2 "fail" --wait 2 --interval 0.5 2>&1)
expect_eq "H2 超时 rc=1" "1" "$?"
expect_contains "H2 超时输出最后一次 FAIL" "❌ 1/1 FAIL" "$out"
expect_contains "H2 超时输出轮询计数" "已轮询" "$out"
n=$(cat "$SEQ_DIR/count" 2>/dev/null || echo 0)
if [ "${n:-0}" -ge 3 ]; then ok "H2 超时轮询次数 ≥3（实际 ${n}）"; else bad "H2 超时轮询次数不足（实际 ${n:-?}）"; fi
if [ -f "$H2_DIR/last_snapshot.json" ]; then bad "H2 超时不应落盘"; else ok "H2 超时不落盘"; fi

out=$(h2 "4,4,pass" --wait 10 2>/dev/null)
expect_eq "H2 空树后通过 rc=0" "0" "$?"
expect_contains "H2 空树后第 3 次通过" "第 3 次" "$out"
h2 "4" --wait 1 --interval 0.5 > /dev/null 2>&1
expect_eq "H2 恒空树 rc=4" "4" "$?"

out=$(h2 "1,4,1,pass" --wait 10 2>/dev/null)
expect_eq "H2 混合序列 1,4,1,pass rc=0（rc=4 重置连败）" "0" "$?"
h2 "1" --wait 10 > /dev/null 2>&1
expect_eq "H2 快照连续失败 rc=5" "5" "$?"
expect_eq "H2 连续失败 2 次即放弃" "2" "$(cat "$SEQ_DIR/count")"
h2 "3" --wait 10 > /dev/null 2>&1
expect_eq "H2 rc=3 速退" "3" "$?"
expect_eq "H2 rc=3 只轮询 1 次" "1" "$(cat "$SEQ_DIR/count")"

bash "$AP" --platform android --has x --wait abc > /dev/null 2>&1
expect_eq "--wait 非整数 rc=2" "2" "$?"
bash "$AP" --platform android --has x --wait -1 > /dev/null 2>&1
expect_eq "--wait 负数 rc=2" "2" "$?"
bash "$AP" --platform android --has x --interval 0 > /dev/null 2>&1
expect_eq "--interval 0 rc=2" "2" "$?"

# --wait 0 与既有行为等价（三条可观察判据）
rm -f "$H1_DIR/last_snapshot.json" "$H1_DIR/prev_snapshot.json"
LOG_DIR="$H1_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$AP" --platform android --has "Loading" > "$TMP/w0_out.txt" 2>&1
expect_eq "--wait 0 通过 rc=0" "0" "$?"
expect_contains "--wait 0 通过首行形状" "✅ 1/1 PASS platform=android" "$(head -1 "$TMP/w0_out.txt")"
cp "$H1_DIR/last_snapshot.json" "$TMP/w0_last1.json"
LOG_DIR="$H1_DIR" SNAPSHOT_INPUT="$TMP/d2.xml" bash "$AP" --platform android --has "Loading" > /dev/null 2>&1
expect_eq "--wait 0 失败 rc=1" "1" "$?"
expect_eq "--wait 0 失败仍写 last" "$(fp_of "$SEQ_DIR/fail.json")" "$(fp_of "$H1_DIR/last_snapshot.json")"
expect_eq "--wait 0 失败仍轮转 prev" "$(fp_of "$TMP/w0_last1.json")" "$(fp_of "$H1_DIR/prev_snapshot.json")"

# 超时附 diff：末轮空树不得污染「产生断言结果那轮」的 payload（P1-1）
rm -f "$H2_DIR/last_snapshot.json" "$H2_DIR/prev_snapshot.json"
LOG_DIR="$H2_DIR" SNAPSHOT_INPUT="$TMP/d1.xml" bash "$SNAP" --platform android --json > /dev/null 2>&1
out=$(h2 "fail,4" --wait 2 --interval 0.5 2>&1)
expect_eq "H2 末轮空树仍 rc=1（有断言结果）" "1" "$?"
expect_contains "H2 超时附 diff" "与上一份快照的差异" "$out"
d_nodes=$(printf '%s\n' "$out" | sed -n 's/.*与上一份快照的差异.*nodes=\([0-9]*\):.*/\1/p' | head -1)
f_nodes=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["nodes"]))' "$SEQ_DIR/fail.json")
expect_eq "H2 超时 diff 的 current 为断言那轮（非末轮空树）" "$f_nodes" "${d_nodes:-x}"

# 断言引擎自身报错（rc=2）透传，不当作「页面没到」重试
rm -f "$SEQ_DIR/count"
SEQ="pass" SEQ_DIR="$SEQ_DIR" LOG_DIR="$H2_DIR" SNAPSHOT_BIN="$TMP/stub_seq.sh" \
  bash "$AP" --platform android --file "$TMP/no_such_assert.txt" --wait 10 > /dev/null 2>&1
expect_eq "--wait 断言文件不存在 rc=2（透传）" "2" "$?"
expect_eq "--wait 断言引擎错误只轮询 1 次" "1" "$(cat "$SEQ_DIR/count")"

out=$(h2 "fail" --wait 1 --interval 0.5 --no-diff 2>&1)
case "$out" in *"与上一份快照的差异"*) bad "--wait --no-diff 仍输出 diff" ;; *) ok "--wait --no-diff 不输出 diff" ;; esac

# ---------- 汇总 ----------
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
