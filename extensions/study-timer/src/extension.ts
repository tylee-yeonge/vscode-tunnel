import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";

// 측정 대상 워크스페이스 경로 (컨테이너 내부 기준)
const TARGET_WORKSPACE = "/workspace/study/physical-ai-study";
const WORKSPACE_NAME = "physical-ai-study";

// 데이터 저장 디렉토리 (docker named volume 마운트 지점)
const DATA_DIR = "/root/.study-timer";

// idle 판정 임계값: 마지막 활동 이후 5분 지나면 카운트 중단
const IDLE_THRESHOLD_MS = 5 * 60 * 1000;

// 미리 보기(webview) 탭이 활성일 때 적용하는 더 큰 임계값.
// webview 내부의 스크롤/클릭/키 입력은 VSCode API로 노출되지 않아 활동 신호를
// 받을 방법이 없으므로, 텍스트 에디터와 동일한 5분을 그대로 적용하면 정상적인
// 장문 markdown 읽기 세션이 부당하게 끊긴다. 트레이드오프로 자리 비움 시
// 최대 20분까지 시간이 부풀려질 수 있음을 수용한다.
const PREVIEW_IDLE_THRESHOLD_MS = 20 * 60 * 1000;

// 1초 tick으로 active 시간을 누적
const TICK_INTERVAL_MS = 1000;

// 30초 주기로 파일 flush (비정상 종료 시 최대 30초 손실)
const FLUSH_INTERVAL_MS = 30 * 1000;

// extensionHost 한 활성화 인스턴스를 식별하는 고유 ID.
// 같은 워크스페이스를 두 창에서 열면 두 인스턴스가 동시에 동작하므로,
// 각자의 세션을 instance_id로 구분하여 서로 다른 세션만 갱신하도록 한다.
const INSTANCE_ID = `${process.pid}-${Math.random().toString(36).slice(2, 8)}`;

interface Session {
    start: string;
    end: string;
    active_seconds: number;
    // 이 세션을 만든 extensionHost 인스턴스 식별자.
    // 구버전(v1.7.x 이하) 파일에는 없을 수 있음.
    instance_id?: string;
}

interface DayFile {
    date: string;
    workspace: string;
    active_seconds: number;
    // 카테고리별(Phase N/weekM, Hardware-Arm/stageN, 또는 other) 누적 초. nanobot에서 소비.
    // v1.5.0 이전 파일에는 없을 수 있으므로 optional로 선언하고 로드 시 마이그레이션.
    by_phase_week?: Record<string, number>;
    // "other" 로 귀속된 tick 의 키별(워크스페이스 상대 경로 또는 sentinel) 누적 초. v1.11.0+.
    // 불변식: sum(other_breakdown.values()) == by_phase_week.other
    // v1.10.x 이하 파일에는 없으므로 optional. 로드 시 ensureOtherBreakdown 으로 마이그레이션.
    other_breakdown?: Record<string, number>;
    sessions: Session[];
    last_updated: string;
}

// 런타임 상태 (activate 이후 유지)
let tickTimer: NodeJS.Timeout | undefined;
let flushTimer: NodeJS.Timeout | undefined;
let focused = true;
let lastActivity = Date.now();
let currentDate = "";
let sessionActiveSeconds = 0;
// 이 인스턴스가 활동하면서 카테고리별로 +1씩 누적한 카운트 (오늘 자기 인스턴스 한정).
// flush 시 lastFlushed와의 delta만 파일의 by_phase_week에 가산하여 다중 인스턴스 합산을 보존.
let myCategoryCounts: Record<string, number> = {};
let myCategoryCountsAtLastFlush: Record<string, number> = {};
// "other" 로 귀속된 tick 의 키별 카운트. myCategoryCounts.other 와 합이 항상 일치.
// 같은 delta-flush 패턴으로 by_phase_week.other 와 other_breakdown 양쪽을 동일 flush 에서 갱신.
let myOtherBreakdown: Record<string, number> = {};
let myOtherBreakdownAtLastFlush: Record<string, number> = {};
// 가장 최근에 활성화되었던 .md 텍스트 에디터의 경로.
// VSCode 기본 markdown preview는 활성 .md를 따라가는 dynamic 동작이라
// "최근 활성 .md == 현재 preview가 보여주는 파일"이 거의 항상 성립한다.
// preview 탭이 활성이라 activeTextEditor가 undefined일 때 카테고리 fallback으로 사용.
let lastActiveMdFile: string | undefined;

// 2자리 0-padding 헬퍼
function pad(n: number): string {
    return String(n).padStart(2, "0");
}

// 로컬 TZ 기준 YYYY-MM-DD 문자열
function localDateString(d: Date): string {
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// 로컬 TZ 기준 ISO8601 타임스탬프 (예: 2026-04-14T09:00:00+09:00)
function localISOString(d: Date): string {
    const offsetMin = -d.getTimezoneOffset();
    const sign = offsetMin >= 0 ? "+" : "-";
    const absOff = Math.abs(offsetMin);
    const offH = pad(Math.floor(absOff / 60));
    const offM = pad(absOff % 60);
    return (
        `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
        `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
        `${sign}${offH}:${offM}`
    );
}

// 해당 로컬 날짜의 23:59:59.999 Date 객체
function endOfLocalDay(dateStr: string): Date {
    const [y, m, d] = dateStr.split("-").map(Number);
    return new Date(y, m - 1, d, 23, 59, 59, 999);
}

// 해당 로컬 날짜의 00:00:00.000 Date 객체
function startOfLocalDay(dateStr: string): Date {
    const [y, m, d] = dateStr.split("-").map(Number);
    return new Date(y, m - 1, d, 0, 0, 0, 0);
}

function filePath(dateStr: string): string {
    return path.join(DATA_DIR, `${dateStr}.json`);
}

// 탭이 markdown preview webview인지 판정
function isMarkdownPreviewTab(tab: vscode.Tab): boolean {
    const input = tab.input;
    if (!(input instanceof vscode.TabInputWebview)) {
        return false;
    }
    // viewType은 보통 "mainThreadWebview-markdown.preview" 형태.
    // 확장이 바뀌어도 깨지지 않도록 substring으로 느슨하게 체크.
    return input.viewType.toLowerCase().includes("markdown");
}

// 미리 보기 탭의 라벨에서 원본 파일명 추출.
// "미리 보기 README.md" → "README.md", "Preview README.md" → "README.md"
function extractPreviewFilename(tab: vscode.Tab): string {
    return tab.label.replace(/^(미리 보기|Preview)\s+/, "");
}

// 현재 활성 탭이 markdown preview(webview)인 경우 원본 .md 파일 경로를 반환한다.
// 매칭 우선순위:
//   1) lastActiveMdFile의 basename이 미리 보기 탭 라벨의 파일명과 일치하면 그 경로
//      (dynamic preview는 활성 .md를 따라가므로 이게 거의 항상 정답)
//   2) 열린 탭 중 같은 basename의 TabInputText가 "유일"하면 그 경로
//   3) 모호하거나 매칭 없음 → undefined ("other"로 귀속)
function getMarkdownPreviewSource(): string | undefined {
    const activeTab = vscode.window.tabGroups.activeTabGroup?.activeTab;
    if (!activeTab || !isMarkdownPreviewTab(activeTab)) {
        return undefined;
    }

    const filename = extractPreviewFilename(activeTab);

    if (lastActiveMdFile && path.basename(lastActiveMdFile) === filename) {
        return lastActiveMdFile;
    }

    let unique: string | undefined;
    let ambiguous = false;
    for (const group of vscode.window.tabGroups.all) {
        for (const t of group.tabs) {
            if (
                t.input instanceof vscode.TabInputText &&
                path.basename(t.input.uri.fsPath) === filename
            ) {
                if (unique) {
                    ambiguous = true;
                } else {
                    unique = t.input.uri.fsPath;
                }
            }
        }
    }
    return ambiguous ? undefined : unique;
}

// 현재 활성 에디터 또는 노트북 에디터의 파일 경로를 반환.
// 우선순위: 텍스트 에디터 → 노트북 에디터 → markdown preview의 원본 .md
function getActiveFsPath(): string | undefined {
    const te = vscode.window.activeTextEditor;
    if (te) {
        return te.document.uri.fsPath;
    }
    const ne = vscode.window.activeNotebookEditor;
    if (ne) {
        return ne.notebook.uri.fsPath;
    }
    return getMarkdownPreviewSource();
}

// 파일 경로에서 카테고리 키 추출
// Studies/Phase N/weekM/ 하위는 "Phase N/weekM",
// Studies/Hardware-Arm/stageN/ 하위는 "Hardware-Arm/stageN",
// 그 외(Hardware-Arm 최상위 문서 포함)는 "other" 로 귀속
function extractCategory(fsPath: string | undefined): string {
    if (!fsPath) {
        return "other";
    }
    const phaseMatch = fsPath.match(/\/Studies\/(Phase \d+)\/(week\d+)(\/|$)/);
    if (phaseMatch) {
        return `${phaseMatch[1]}/${phaseMatch[2]}`;
    }
    const armMatch = fsPath.match(/\/Studies\/Hardware-Arm\/(stage\d+)(\/|$)/);
    if (armMatch) {
        return `Hardware-Arm/${armMatch[1]}`;
    }
    return "other";
}

// 일별 JSON 파일 읽기 (없거나 파싱 실패 시 null)
function readDayFile(dateStr: string): DayFile | null {
    const p = filePath(dateStr);
    if (!fs.existsSync(p)) {
        return null;
    }
    try {
        const raw = fs.readFileSync(p, "utf8");
        return JSON.parse(raw) as DayFile;
    } catch {
        return null;
    }
}

// tmp 파일 작성 후 rename으로 atomic write, 권한 0644
function writeDayFile(data: DayFile): void {
    if (!fs.existsSync(DATA_DIR)) {
        fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o755 });
    }
    const p = filePath(data.date);
    const tmp = `${p}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o644 });
    fs.renameSync(tmp, p);
}

// sessions 합으로 top-level active_seconds 재계산
function sumSessions(data: DayFile): number {
    return data.sessions.reduce((s, x) => s + x.active_seconds, 0);
}

// 구버전(v1.5.0 이전) by_phase_week 누락 파일을 in-place로 마이그레이션
// 불변식 active_seconds == sum(by_phase_week)을 유지하기 위해 누락 분은 "other"로 귀속
function ensureByPhaseWeek(data: DayFile): void {
    if (data.by_phase_week && typeof data.by_phase_week === "object") {
        return;
    }
    data.by_phase_week = data.active_seconds > 0 ? { other: data.active_seconds } : {};
}

// 구버전(v1.10.x 이하) other_breakdown 누락 파일을 in-place 마이그레이션.
// 과거 데이터의 실제 내역은 복구 불가하므로 (legacy unattributed) sentinel 로 묶어 불변식 유지.
// 불변식: sum(other_breakdown.values()) == by_phase_week.other
function ensureOtherBreakdown(data: DayFile): void {
    if (data.other_breakdown && typeof data.other_breakdown === "object") {
        return;
    }
    const otherSec = data.by_phase_week?.other ?? 0;
    data.other_breakdown = otherSec > 0 ? { "(legacy unattributed)": otherSec } : {};
}

// fsPath -> other_breakdown 키. extractCategory 가 "other" 반환 시에만 호출.
// 워크스페이스 내부면 상대 경로, 외부면 absolute 그대로, undefined 면 sentinel.
function otherBreakdownKey(fsPath: string | undefined): string {
    if (!fsPath) {
        return "(no active editor)";
    }
    if (fsPath.startsWith(TARGET_WORKSPACE + "/")) {
        return path.relative(TARGET_WORKSPACE, fsPath);
    }
    return fsPath;
}

// 자기 인스턴스 세션을 새로 추가하고 currentSessionIndex를 기록
// 다중 인스턴스 충돌을 막기 위해 activate/자정 분할 모두 항상 새 세션을 만든다.
// (구버전의 RESUME 로직은 두 인스턴스가 같은 세션을 공유하여 active_seconds가
//  서로 덮어쓰이는 문제가 있어 v1.8.0에서 제거)
function initSessionForDate(dateStr: string, sessStart: Date): void {
    currentDate = dateStr;
    sessionActiveSeconds = 0;
    myCategoryCounts = {};
    myCategoryCountsAtLastFlush = {};
    myOtherBreakdown = {};
    myOtherBreakdownAtLastFlush = {};

    const loaded = readDayFile(dateStr);
    const data: DayFile = loaded || {
        date: dateStr,
        workspace: WORKSPACE_NAME,
        active_seconds: 0,
        by_phase_week: {},
        other_breakdown: {},
        sessions: [],
        last_updated: localISOString(new Date()),
    };

    ensureByPhaseWeek(data);
    ensureOtherBreakdown(data);

    // 자기 인스턴스의 새 세션 추가
    data.sessions.push({
        start: localISOString(sessStart),
        end: localISOString(sessStart),
        active_seconds: 0,
        instance_id: INSTANCE_ID,
    });
    data.active_seconds = sumSessions(data);
    data.last_updated = localISOString(new Date());
    writeDayFile(data);
}

// 현재 인스턴스가 만든 세션을 instance_id로 찾는다. 없으면 -1.
function findMySessionIndex(data: DayFile): number {
    return data.sessions.findIndex((s) => s.instance_id === INSTANCE_ID);
}

// 자기 세션의 end/active_seconds 및 by_phase_week / other_breakdown delta를 파일에 반영
function flush(endDate?: Date): void {
    const data = readDayFile(currentDate);
    if (!data) {
        return;
    }
    ensureByPhaseWeek(data);
    ensureOtherBreakdown(data);

    const myIdx = findMySessionIndex(data);
    if (myIdx < 0) {
        // 외부에서 자기 세션이 사라진 경우(예: 다른 도구가 파일을 재작성).
        // 다음 tick에서 새로 만들기보다 그냥 이번 flush는 건너뛴다 — 다음 자정 분할에서 정상화됨.
        return;
    }

    const now = endDate ?? new Date();
    data.sessions[myIdx].end = localISOString(now);
    data.sessions[myIdx].active_seconds = sessionActiveSeconds;

    // by_phase_week: 이 인스턴스가 마지막 flush 이후 증가시킨 분(delta)만 가산
    const bpw = data.by_phase_week!;
    for (const [k, v] of Object.entries(myCategoryCounts)) {
        const prev = myCategoryCountsAtLastFlush[k] ?? 0;
        const delta = v - prev;
        if (delta > 0) {
            bpw[k] = (bpw[k] ?? 0) + delta;
        }
    }
    myCategoryCountsAtLastFlush = { ...myCategoryCounts };

    // other_breakdown: 같은 delta 패턴. by_phase_week.other 가산과 같은 flush 호출에서 처리하여 불변식 유지.
    const ob = data.other_breakdown!;
    for (const [k, v] of Object.entries(myOtherBreakdown)) {
        const prev = myOtherBreakdownAtLastFlush[k] ?? 0;
        const delta = v - prev;
        if (delta > 0) {
            ob[k] = (ob[k] ?? 0) + delta;
        }
    }
    myOtherBreakdownAtLastFlush = { ...myOtherBreakdown };

    data.active_seconds = sumSessions(data);
    data.last_updated = localISOString(new Date());
    writeDayFile(data);
}

// 매 초 호출: 자정 분할 처리 및 active 판정
function tick(): void {
    const now = new Date();
    const todayStr = localDateString(now);

    // 자정 경계: 현재 세션을 23:59:59로 마감하고 새 날짜에 새 세션 시작
    if (todayStr !== currentDate) {
        flush(endOfLocalDay(currentDate));
        initSessionForDate(todayStr, startOfLocalDay(todayStr));
    }

    // 활성 탭이 미리 보기면 더 큰 idle 임계 적용 (webview 활동 신호 부재 보정)
    const activeTab = vscode.window.tabGroups.activeTabGroup?.activeTab;
    const previewActive = activeTab !== undefined && isMarkdownPreviewTab(activeTab);
    const threshold = previewActive ? PREVIEW_IDLE_THRESHOLD_MS : IDLE_THRESHOLD_MS;

    // focus 상태이고 최근 활동이 임계 내였으면 active
    const idle = now.getTime() - lastActivity >= threshold;
    if (focused && !idle) {
        sessionActiveSeconds++;
        // 현재 활성 에디터의 카테고리에도 1초 가산 (sessionActiveSeconds와 짝지어 불변식 유지)
        const fsPath = getActiveFsPath();
        const category = extractCategory(fsPath);
        myCategoryCounts[category] = (myCategoryCounts[category] ?? 0) + 1;
        // other 분기: by_phase_week.other 와 짝지어 other_breakdown 의 키별 카운트도 함께 증가.
        // 같은 if 블록 안에서 두 카운터를 동시에 +1 하여 불변식 sum(other_breakdown) == by_phase_week.other 유지.
        if (category === "other") {
            const key = otherBreakdownKey(fsPath);
            myOtherBreakdown[key] = (myOtherBreakdown[key] ?? 0) + 1;
        }
    }
}

export function activate(context: vscode.ExtensionContext): void {
    // 최상위 워크스페이스 폴더가 대상 경로와 일치할 때만 활성화
    const folders = vscode.workspace.workspaceFolders;
    if (!folders || folders.length === 0) {
        return;
    }
    const firstPath = folders[0].uri.fsPath;
    if (
        firstPath !== TARGET_WORKSPACE &&
        path.basename(firstPath) !== WORKSPACE_NAME
    ) {
        return;
    }

    // 초기 상태 설정
    const now = new Date();
    focused = vscode.window.state.focused;
    lastActivity = now.getTime();

    // 자기 인스턴스의 새 세션 시작 (다중 인스턴스 충돌 방지를 위해 항상 새로 추가)
    initSessionForDate(localDateString(now), now);

    // 활동 이벤트 구독: 발생 시 lastActivity 갱신
    const bump = () => {
        lastActivity = Date.now();
    };
    // 활성 텍스트 에디터가 .md면 lastActiveMdFile에 기억해두고 활동도 갱신.
    // 이후 markdown preview 탭으로 전환되어 activeTextEditor가 undefined가 되어도
    // 카테고리 추출에 사용할 수 있다.
    const onActiveTextEditor = (editor: vscode.TextEditor | undefined) => {
        bump();
        if (editor && editor.document.uri.fsPath.toLowerCase().endsWith(".md")) {
            lastActiveMdFile = editor.document.uri.fsPath;
        }
    };
    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument(bump),
        vscode.window.onDidChangeTextEditorSelection(bump),
        vscode.window.onDidChangeActiveTextEditor(onActiveTextEditor),
        // 탭 전환(미리 보기 탭으로 이동 포함) 시에도 활동으로 간주.
        // webview 내부의 스크롤/클릭은 API로 노출되지 않아 idle 5분 임계는 그대로 적용됨.
        vscode.window.tabGroups.onDidChangeTabs(bump),
        vscode.window.onDidChangeWindowState((state) => {
            focused = state.focused;
            // focus 복귀는 활동으로 간주
            if (state.focused) {
                lastActivity = Date.now();
            }
        })
    );

    // activate 시점에 이미 .md가 활성 에디터일 수도 있으므로 한 번 초기화
    onActiveTextEditor(vscode.window.activeTextEditor);

    // 타이머 등록
    tickTimer = setInterval(tick, TICK_INTERVAL_MS);
    flushTimer = setInterval(() => flush(), FLUSH_INTERVAL_MS);

    // dispose 시 타이머 정리 및 최종 flush + 빈 세션 정리
    context.subscriptions.push({
        dispose: () => {
            shutdown();
        },
    });
}

// 타이머 정리, 최종 flush, 그리고 이 인스턴스가 만든 0초짜리 세션 제거.
// reload/창 닫기 시마다 빈 세션이 누적되는 것을 막는다.
function shutdown(): void {
    if (tickTimer) {
        clearInterval(tickTimer);
        tickTimer = undefined;
    }
    if (flushTimer) {
        clearInterval(flushTimer);
        flushTimer = undefined;
    }
    flush();

    const data = readDayFile(currentDate);
    if (!data) {
        return;
    }
    const myIdx = findMySessionIndex(data);
    if (myIdx >= 0 && data.sessions[myIdx].active_seconds === 0) {
        data.sessions.splice(myIdx, 1);
        data.active_seconds = sumSessions(data);
        data.last_updated = localISOString(new Date());
        writeDayFile(data);
    }
}

export function deactivate(): void {
    shutdown();
}
