#!/bin/sh
# lib/timeutil.sh —— 日期與時區算術
#
# 為什麼不用 `date -d`：POSIX date 完全沒有算術能力，GNU 是 `-d`、BSD 是 `-v/-j -f`，
# 分支寫下去就是三份程式碼。這裡把 civil↔epoch 換算做在 awk 裡（Howard Hinnant 的
# days_from_civil），只跟 awk 借整數運算，任何平台結果一致。
#
# ⚠ 已知限制：時區偏移取自「現在」（date +%z），不是目標日期當下的偏移。
#   台北無 DST 所以無影響；若哪天要處理有 DST 的時區，這裡要改成查目標日正午的偏移。

# 本機時區偏移（秒）。+0800 → 28800
jr_tz_offset() {
	_z=$(date +%z 2>/dev/null)
	case $_z in
		[+-][0-9][0-9][0-9][0-9]) ;;
		*) printf '0'; return 0 ;;
	esac
	_sign=$(printf '%s' "$_z" | cut -c1)
	_hh=$(printf '%s' "$_z" | cut -c2-3)
	_mm=$(printf '%s' "$_z" | cut -c4-5)
	_s=$(( ${_hh#0} * 3600 + ${_mm#0} * 60 ))
	[ "$_sign" = '-' ] && _s=$(( 0 - _s ))
	printf '%s' "$_s"
}

# JOURNAL_TODAY 是測試縫：冒煙測試的 fixture 日期是固定的，capture 的
# 「今天」必須能被釘住。正常執行時永遠不設。
jr_today() {
	if [ -n "${JOURNAL_TODAY:-}" ]; then printf '%s' "$JOURNAL_TODAY"; else date +%Y-%m-%d; fi
}
jr_now_iso() { date +%Y-%m-%dT%H:%M:%S%z | sed 's/\(..\)$/:\1/'; }
jr_now_epoch() {
	_e=$(date +%s 2>/dev/null)
	case $_e in
		''|*[!0-9]*) printf '0' ;;
		*) printf '%s' "$_e" ;;
	esac
}

jr_date_valid() {
	case $1 in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
		*) return 1 ;;
	esac
}

# jr_day_window LOCAL_DATE  → 印出 "START_UTC END_UTC"（ISO Z 字串，半開區間 [start, end)）
#
# transcript 的 timestamp 是 UTC（…Z），而我們要切的是「本機的那一天」。
# 兩者可以直接做字串比較，因為 ISO-8601 Z 格式的字典序等同時間序。
jr_day_window() {
	_d=$1
	_off=$(jr_tz_offset)
	awk -v d="$_d" -v off="$_off" '
		function days_from_civil(y, m, dd,    yy, era, yoe, doy, doe) {
			yy = (m <= 2) ? y - 1 : y
			era = int((yy >= 0 ? yy : yy - 399) / 400)
			yoe = yy - era * 400
			doy = int((153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5) + dd - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		function civil_from_days(z,    era, doe, yoe, y, doy, mp, dd, m) {
			z += 719468
			era = int((z >= 0 ? z : z - 146096) / 146097)
			doe = z - era * 146097
			yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
			y = yoe + era * 400
			doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
			mp = int((5 * doy + 2) / 153)
			dd = doy - int((153 * mp + 2) / 5) + 1
			m = mp + ((mp < 10) ? 3 : -9)
			if (m <= 2) y += 1
			return sprintf("%04d-%02d-%02d", y, m, dd)
		}
		function iso_z(ep,    days, rem, h, mi, s) {
			days = int(ep / 86400)
			rem = ep - days * 86400
			if (rem < 0) { rem += 86400; days -= 1 }
			h = int(rem / 3600); mi = int((rem % 3600) / 60); s = rem % 60
			return sprintf("%sT%02d:%02d:%02dZ", civil_from_days(days), h, mi, s)
		}
		BEGIN {
			y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
			start_local = days_from_civil(y, m, dd) * 86400
			printf "%s %s\n", iso_z(start_local - off), iso_z(start_local + 86400 - off)
		}'
}

# jr_days_between DATE1 DATE2 → 印出 DATE2 - DATE1 的天數
jr_days_between() {
	awk -v a="$1" -v b="$2" '
		function days_from_civil(y, m, dd,    yy, era, yoe, doy, doe) {
			yy = (m <= 2) ? y - 1 : y
			era = int((yy >= 0 ? yy : yy - 399) / 400)
			yoe = yy - era * 400
			doy = int((153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5) + dd - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		function d2n(s) { return days_from_civil(substr(s,1,4)+0, substr(s,6,2)+0, substr(s,9,2)+0) }
		BEGIN { print d2n(b) - d2n(a) }'
}

# jr_iso_week DATE → 2026-W31（ISO 8601：週一起算，該週的週四決定年份）
jr_iso_week() {
	awk -v d="$1" '
		function days_from_civil(y, m, dd,    yy, era, yoe, doy, doe) {
			yy = (m <= 2) ? y - 1 : y
			era = int((yy >= 0 ? yy : yy - 399) / 400)
			yoe = yy - era * 400
			doy = int((153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5) + dd - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		function civil_year(z,    era, doe, yoe, y, doy) {
			z += 719468
			era = int((z >= 0 ? z : z - 146096) / 146097)
			doe = z - era * 146097
			yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
			y = yoe + era * 400
			doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
			if (int((5 * doy + 2) / 153) + ((int((5 * doy + 2) / 153) < 10) ? 3 : -9) <= 2) y += 1
			return y
		}
		BEGIN {
			days = days_from_civil(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0)
			dow = ((days % 7) + 7 + 3) % 7 + 1          # Mon=1..Sun=7（epoch 日 0 = 週四）
			thu = days + (4 - dow)
			y = civil_year(thu)
			week = int((thu - days_from_civil(y, 1, 1)) / 7) + 1
			printf "%04d-W%02d\n", y, week
		}'
}

# jr_week_dates DATE → 該 ISO 週的七個日期（週一到週日，一行一個）
jr_week_dates() {
	_dow=$(awk -v d="$1" '
		function days_from_civil(y, m, dd,    yy, era, yoe, doy, doe) {
			yy = (m <= 2) ? y - 1 : y
			era = int((yy >= 0 ? yy : yy - 399) / 400)
			yoe = yy - era * 400
			doy = int((153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5) + dd - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		BEGIN {
			days = days_from_civil(substr(d,1,4)+0, substr(d,6,2)+0, substr(d,9,2)+0)
			print ((days % 7) + 7 + 3) % 7 + 1
		}')
	_mon=$(jr_date_shift "$1" "$((1 - _dow))")
	_i=0
	while [ $_i -lt 7 ]; do
		jr_date_shift "$_mon" "$_i"
		_i=$((_i + 1))
	done
}

# jr_date_shift DATE DAYS → 印出位移後的日期
jr_date_shift() {
	awk -v d="$1" -v n="$2" '
		function days_from_civil(y, m, dd,    yy, era, yoe, doy, doe) {
			yy = (m <= 2) ? y - 1 : y
			era = int((yy >= 0 ? yy : yy - 399) / 400)
			yoe = yy - era * 400
			doy = int((153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5) + dd - 1
			doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
			return era * 146097 + doe - 719468
		}
		function civil_from_days(z,    era, doe, yoe, y, doy, mp, dd, m) {
			z += 719468
			era = int((z >= 0 ? z : z - 146096) / 146097)
			doe = z - era * 146097
			yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
			y = yoe + era * 400
			doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
			mp = int((5 * doy + 2) / 153)
			dd = doy - int((153 * mp + 2) / 5) + 1
			m = mp + ((mp < 10) ? 3 : -9)
			if (m <= 2) y += 1
			return sprintf("%04d-%02d-%02d", y, m, dd)
		}
		BEGIN {
			y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
			print civil_from_days(days_from_civil(y, m, dd) + n)
		}'
}
