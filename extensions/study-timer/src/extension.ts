import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";

// 측정 대상 워크스페이스 경로 (컨테이너 내부 기준)
const TARGET_WORKSPACE = "/workspace/study/visual-slam-and-perception-learning";
const WORKSPACE_NAME = "visual-slam-and-perception-learning";

// 데이터 저장 디렉토리 (docker named volume 마운트 지점)
const DATA_DIR = "/root/.study-timer";

// idle 판정 임계값: 마지막 활동 이후 5분 지나면 카운트 중단
const IDLE_THRESHOLD_MS = 5 * 60 * 1000;

// 1초 tick으로 active 시간을 누적
const TICK_INTERVAL_MS = 1000;

// 30초 주기로 파일 flush (비정상 종료 시 최대 30초 손실)
const FLUSH_INTERVAL_MS = 30 * 1000;

// activate 시 최근 N분 이내에 업데이트된 세션은 이어받기
// (VS Code reload 등으로 deactivate 없이 재활성화될 때 세션 중복 방지)
const RESUME_THRESHOLD_MS = 5 * 60 * 1000;

interface Session {
    start: string;
    end: string;
    active_seconds: number;
}

interface DayFile {
    date: string;
    workspace: string;
    active_seconds: number;
    // 카테고리별(Phase N/weekM 또는 other) 누적 초. nanobot에서 소비.
    // v1.5.0 이전 파일에는 없을 수 있으므로 optional로 선언하고 로드 시 마이그레이션.
    by_phase_week?: Record<string, number>;
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
let currentSessionIndex = -1;
// 카테고리별 누적 초 (하루 단위). 자정 분할 시 리셋.
let byPhaseWeek: Record<string, number> = {};

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

// 현재 활성 에디터 또는 노트북 에디터의 파일 경로를 반환
// 텍스트 에디터가 우선, 없으면 노트북 에디터로 fallback
function getActiveFsPath(): string | undefined {
    const te = vscode.window.activeTextEditor;
    if (te) {
        return te.document.uri.fsPath;
    }
    const ne = vscode.window.activeNotebookEditor;
    if (ne) {
        return ne.notebook.uri.fsPath;
    }
    return undefined;
}

// 파일 경로에서 Phase/week 카테고리 키 추출
// Studies/Phase N/weekM/ 하위만 분류, 그 외는 전부 "other"
function extractCategory(fsPath: string | undefined): string {
    if (!fsPath) {
        return "other";
    }
    const m = fsPath.match(/\/Studies\/(Phase \d+)\/(week\d+)(\/|$)/);
    if (m) {
        return `${m[1]}/${m[2]}`;
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

// 기존 DayFile의 by_phase_week를 런타임 상태로 로드
// 필드가 없는 구버전 파일은 {"other": active_seconds}로 백필하여 불변식 유지
function loadByPhaseWeek(data: DayFile): void {
    if (data.by_phase_week && typeof data.by_phase_week === "object") {
        byPhaseWeek = { ...data.by_phase_week };
        return;
    }
    // 마이그레이션: 필드 없는 기존 파일은 전체 누적을 other로 간주
    byPhaseWeek = data.active_seconds > 0 ? { other: data.active_seconds } : {};
}

// 세션을 시작하거나 최근 세션을 이어받아 인덱스를 기록
// resume=true: 기존 마지막 세션이 RESUME_THRESHOLD_MS 이내면 이어받기 (activate 시)
// resume=false: 항상 새 세션 추가 (자정 분할 시)
function initSessionForDate(
    dateStr: string,
    sessStart: Date,
    resume: boolean
): void {
    currentDate = dateStr;
    sessionActiveSeconds = 0;

    const loaded = readDayFile(dateStr);
    const existing: DayFile = loaded || {
        date: dateStr,
        workspace: WORKSPACE_NAME,
        active_seconds: 0,
        by_phase_week: {},
        sessions: [],
        last_updated: localISOString(new Date()),
    };

    // 기존 파일이 있으면 by_phase_week 로드 (구버전 마이그레이션 포함)
    // 자정 분할(resume=false)이며 새 날짜 파일이 없는 경우에는 빈 객체로 시작
    if (loaded) {
        loadByPhaseWeek(loaded);
    } else {
        byPhaseWeek = {};
    }

    // 이어받기 조건: activate 직후 && 기존 마지막 세션의 end가 최근
    if (resume && existing.sessions.length > 0) {
        const last = existing.sessions[existing.sessions.length - 1];
        const lastEndMs = Date.parse(last.end);
        if (
            !isNaN(lastEndMs) &&
            Date.now() - lastEndMs <= RESUME_THRESHOLD_MS
        ) {
            currentSessionIndex = existing.sessions.length - 1;
            sessionActiveSeconds = last.active_seconds;
            existing.by_phase_week = byPhaseWeek;
            existing.last_updated = localISOString(new Date());
            writeDayFile(existing);
            return;
        }
    }

    // 새 세션 추가 (하루 누적 by_phase_week는 유지)
    existing.sessions.push({
        start: localISOString(sessStart),
        end: localISOString(sessStart),
        active_seconds: 0,
    });
    currentSessionIndex = existing.sessions.length - 1;
    existing.by_phase_week = byPhaseWeek;
    existing.last_updated = localISOString(new Date());
    writeDayFile(existing);
}

// 현재 세션의 end/active_seconds 및 byPhaseWeek를 파일에 반영
function flush(endDate?: Date): void {
    const data = readDayFile(currentDate);
    if (!data) {
        return;
    }
    const now = endDate ?? new Date();
    if (currentSessionIndex >= 0 && currentSessionIndex < data.sessions.length) {
        data.sessions[currentSessionIndex].end = localISOString(now);
        data.sessions[currentSessionIndex].active_seconds = sessionActiveSeconds;
    }
    data.active_seconds = data.sessions.reduce((s, x) => s + x.active_seconds, 0);
    data.by_phase_week = byPhaseWeek;
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
        initSessionForDate(todayStr, startOfLocalDay(todayStr), false);
    }

    // focus 상태이고 최근 5분 이내 활동이 있었으면 active
    const idle = now.getTime() - lastActivity >= IDLE_THRESHOLD_MS;
    if (focused && !idle) {
        sessionActiveSeconds++;
        // 현재 활성 에디터의 카테고리에도 1초 가산 (불변식 유지)
        const category = extractCategory(getActiveFsPath());
        byPhaseWeek[category] = (byPhaseWeek[category] ?? 0) + 1;
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

    // 세션 시작 (최근 세션 이어받기 시도, 없으면 새 세션 추가)
    initSessionForDate(localDateString(now), now, true);

    // 활동 이벤트 구독: 발생 시 lastActivity 갱신
    const bump = () => {
        lastActivity = Date.now();
    };
    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument(bump),
        vscode.window.onDidChangeTextEditorSelection(bump),
        vscode.window.onDidChangeActiveTextEditor(bump),
        vscode.window.onDidChangeWindowState((state) => {
            focused = state.focused;
            // focus 복귀는 활동으로 간주
            if (state.focused) {
                lastActivity = Date.now();
            }
        })
    );

    // 타이머 등록
    tickTimer = setInterval(tick, TICK_INTERVAL_MS);
    flushTimer = setInterval(() => flush(), FLUSH_INTERVAL_MS);

    // dispose 시 타이머 정리 및 최종 flush
    context.subscriptions.push({
        dispose: () => {
            if (tickTimer) {
                clearInterval(tickTimer);
            }
            if (flushTimer) {
                clearInterval(flushTimer);
            }
            flush();
        },
    });
}

export function deactivate(): void {
    if (tickTimer) {
        clearInterval(tickTimer);
    }
    if (flushTimer) {
        clearInterval(flushTimer);
    }
    flush();
}
