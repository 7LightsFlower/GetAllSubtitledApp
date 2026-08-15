// Live notes side-panel. Buffers notes per language; renders the currently
// active one. Edits + user-added notes are overlaid from localStorage.
//
// window.NotesPanel: appendNote, showGlobalSummary, onChapterBreak,
//                    onChapterHeading, setExpanded.
(function () {
    'use strict';

    const STORAGE_KEY = 'notes_panel_expanded';
    const WIDTH_STORAGE_KEY = 'notes_panel_width';
    const DEFAULT_WIDTH = 320;
    const MIN_WIDTH = 240;
    const MAX_WIDTH_VW_FRAC = 0.7;  // don't let the panel eat more than 70% of viewport

    // Per-language state — populated regardless of which lang is rendered.
    const notesStoreByLang = {};      // lang_id -> [{seq, start, end, level, chapterIdx}]
    const chapterIndexByLang = {};    // lang_id -> current chapter index (counts up on chapterBreak)
    const chapterTitleByLang = {};    // lang_id -> { chapter_idx: title }
    const globalSummaryByLang = {};   // lang_id -> latest global summary text
    // textstructurer can re-emit chapterBreak at the same start; dedup here.
    const lastBreakStartByLang = {};
    const chapterBreakTimesByLang = {};

    let currentRenderedLang = null;
    let chapterSectionsCurrent = {};
    // Suppress per-note autoscroll during bulk rebuilds; scroll once at the end.
    let bulkRendering = false;

    const editsByLang = {};
    const EDITS_STORAGE_PREFIX = 'notes_edits';
    const VIEW_MODE_STORAGE_KEY = 'notes_view_mode';
    let currentViewMode = (localStorage.getItem(VIEW_MODE_STORAGE_KEY) || 'edited') === 'original' ? 'original' : 'edited';

    let panelExpanded = (localStorage.getItem(STORAGE_KEY) || '1') === '1';
    let panelInitialized = false;

    // ----- Storage / helpers --------------------------------------------------

    function storeExpanded(v) {
        try { localStorage.setItem(STORAGE_KEY, v ? '1' : '0'); } catch (e) {}
    }

    function clampWidth(w) {
        const max = Math.max(MIN_WIDTH, Math.round(window.innerWidth * MAX_WIDTH_VW_FRAC));
        if (!isFinite(w)) return DEFAULT_WIDTH;
        return Math.min(max, Math.max(MIN_WIDTH, Math.round(w)));
    }

    function loadWidth() {
        try {
            const raw = localStorage.getItem(WIDTH_STORAGE_KEY);
            if (raw) {
                const n = parseInt(raw, 10);
                if (isFinite(n)) return clampWidth(n);
            }
        } catch (e) {}
        return DEFAULT_WIDTH;
    }

    function applyWidth(w) {
        const px = clampWidth(w) + 'px';
        document.documentElement.style.setProperty('--notes-panel-width', px);
    }

    function storeWidth(w) {
        try { localStorage.setItem(WIDTH_STORAGE_KEY, String(clampWidth(w))); } catch (e) {}
    }

    // ----- Edit overlay (per-session, per-lang) -------------------------------

    function getSessionId() {
        return String(window.sessionId || 'unknown');
    }

    function editsStorageKey(lang_id) {
        return EDITS_STORAGE_PREFIX + ':' + getSessionId() + ':' + String(lang_id);
    }

    function loadEdits(lang_id) {
        const key = String(lang_id);
        if (editsByLang[key]) return editsByLang[key];
        let parsed = null;
        try {
            const raw = localStorage.getItem(editsStorageKey(key));
            if (raw) parsed = JSON.parse(raw);
        } catch (e) {}
        if (!parsed || typeof parsed !== 'object') parsed = {};
        if (!parsed.byId || typeof parsed.byId !== 'object') parsed.byId = {};
        if (!Array.isArray(parsed.userAdded)) parsed.userAdded = [];
        editsByLang[key] = parsed;
        return parsed;
    }

    function saveEdits(lang_id) {
        const key = String(lang_id);
        const data = editsByLang[key];
        if (!data) return;
        try { localStorage.setItem(editsStorageKey(key), JSON.stringify(data)); } catch (e) {}
    }

    function getNoteId(note) {
        return String(note.chapterIdx) + ':' + String(note.start);
    }

    function getEditState(lang_id, noteId) {
        const data = loadEdits(lang_id);
        return data.byId[noteId] || null;
    }

    function setEditedText(lang_id, noteId, text) {
        const data = loadEdits(lang_id);
        const trimmed = String(text || '').trim();
        if (!trimmed) {
            if (data.byId[noteId]) {
                delete data.byId[noteId].editedText;
                if (!data.byId[noteId].deleted) delete data.byId[noteId];
            }
        } else {
            if (!data.byId[noteId]) data.byId[noteId] = {};
            data.byId[noteId].editedText = trimmed;
        }
        saveEdits(lang_id);
    }

    function markDeleted(lang_id, noteId, deleted) {
        const data = loadEdits(lang_id);
        if (deleted) {
            if (!data.byId[noteId]) data.byId[noteId] = {};
            data.byId[noteId].deleted = true;
        } else if (data.byId[noteId]) {
            delete data.byId[noteId].deleted;
            if (data.byId[noteId].editedText == null) delete data.byId[noteId];
        }
        saveEdits(lang_id);
    }

    function randomUserNoteId() {
        return 'ua-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
    }

    function addUserNote(lang_id, chapterIdx, text, level, insertedAfter) {
        const data = loadEdits(lang_id);
        const trimmed = String(text || '').trim();
        if (!trimmed) return null;
        const entry = {
            id: randomUserNoteId(),
            chapterIdx: parseInt(chapterIdx, 10) || 1,
            level: (parseInt(level, 10) || 0) >= 1 ? 1 : 0,
            text: trimmed,
            insertedAfter: insertedAfter || null,
        };
        data.userAdded.push(entry);
        saveEdits(lang_id);
        return entry;
    }

    function updateUserNote(lang_id, id, text) {
        const data = loadEdits(lang_id);
        const trimmed = String(text || '').trim();
        const idx = data.userAdded.findIndex(function (n) { return n.id === id; });
        if (idx < 0) return;
        if (!trimmed) {
            data.userAdded.splice(idx, 1);
        } else {
            data.userAdded[idx].text = trimmed;
        }
        saveEdits(lang_id);
    }

    function removeUserNote(lang_id, id) {
        const data = loadEdits(lang_id);
        const idx = data.userAdded.findIndex(function (n) { return n.id === id; });
        if (idx < 0) return;
        data.userAdded.splice(idx, 1);
        saveEdits(lang_id);
    }

    function userNotesForChapter(lang_id, chapterIdx) {
        const data = loadEdits(lang_id);
        const ci = parseInt(chapterIdx, 10);
        return data.userAdded.filter(function (n) { return n.chapterIdx === ci; });
    }

    function escapeHtml(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function formatTime(t) {
        const s = parseFloat(t);
        if (isNaN(s)) return '';
        const m = Math.floor(s / 60);
        const sec = Math.floor(s % 60);
        return String(m).padStart(2, '0') + ':' + String(sec).padStart(2, '0');
    }

    function scrollTranscriptToStart(start) {
        try {
            const startNum = parseFloat(start);
            if (isNaN(startNum)) return;
            const targets = document.querySelectorAll('[start]');
            for (const el of targets) {
                const s = parseFloat(el.getAttribute('start'));
                if (!isNaN(s) && s >= startNum) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    el.classList.add('notes-jump-highlight');
                    setTimeout(function () { el.classList.remove('notes-jump-highlight'); }, 1500);
                    break;
                }
            }
        } catch (e) {}
    }

    // session.html's lang_visible/lang_index are scoped `let`s mirrored to
    // body.dataset via Proxy; read the dataset to see them from this script.
    function readDatasetObj(key) {
        try {
            const raw = document.body && document.body.dataset && document.body.dataset[key];
            if (!raw) return {};
            const o = JSON.parse(raw);
            return (o && typeof o === 'object') ? o : {};
        } catch (e) {
            return {};
        }
    }

    function getActiveLangId() {
        const lvis = readDatasetObj('langVisible');
        const lidx = readDatasetObj('langIndex');
        // Prefer the leftmost visible language.
        for (const code of Object.keys(lvis)) {
            const v = lvis[code];
            if (v === 1 || v === '1') {
                if (lidx[code] != null) return String(lidx[code]);
            }
        }
        return null;
    }

    function formatChapterLabel(title, chapterIdx) {
        const t = (title || '').trim();
        return t ? ('Chapter ' + chapterIdx + ' — ' + t) : ('Chapter ' + chapterIdx);
    }

    function ensureChapterSection(lang_id, ci) {
        if (chapterSectionsCurrent[ci]) return chapterSectionsCurrent[ci];
        const body = document.getElementById('notesPanelBody');
        if (!body) return null;

        const section = document.createElement('section');
        section.className = 'notes-panel-chapter';
        section.dataset.chapterIdx = String(ci);

        const title = (chapterTitleByLang[lang_id] && chapterTitleByLang[lang_id][ci]) || '';
        const headerEl = document.createElement('div');
        headerEl.className = 'notes-panel-chapter-header';
        headerEl.innerHTML =
            '<span class="notes-panel-chapter-caret">▾</span>' +
            '<span class="notes-panel-chapter-label"></span>' +
            '<span class="notes-panel-chapter-count">0</span>';
        headerEl.querySelector('.notes-panel-chapter-label').textContent =
            formatChapterLabel(title, ci);
        headerEl.addEventListener('click', function () {
            section.classList.toggle('collapsed');
        });

        const bodyEl = document.createElement('div');
        bodyEl.className = 'notes-panel-chapter-body';

        // tailEl pins the "+ Add note" row at the bottom; notes insert before it.
        const tailEl = document.createElement('div');
        tailEl.className = 'notes-panel-chapter-tail';
        bodyEl.appendChild(tailEl);

        section.appendChild(headerEl);
        section.appendChild(bodyEl);

        // Insert in chapter-index order — late notes for older chapters would
        // otherwise produce 1, 3, 5, 4, 6.
        let insertBefore = null;
        const existingSections = body.querySelectorAll(':scope > .notes-panel-chapter');
        for (const s of existingSections) {
            const sIdx = parseInt(s.dataset.chapterIdx, 10);
            if (Number.isFinite(sIdx) && sIdx > ci) {
                insertBefore = s;
                break;
            }
        }
        body.insertBefore(section, insertBefore);

        // Newest chapter stays expanded; late older chapters open collapsed.
        // Sections with an active editor are left alone.
        const existingIdxs = Object.keys(chapterSectionsCurrent).map(Number).filter(Number.isFinite);
        const maxExistingIdx = existingIdxs.length ? Math.max.apply(null, existingIdxs) : 0;
        if (ci >= maxExistingIdx) {
            for (const k of existingIdxs) {
                const prev = chapterSectionsCurrent[k];
                if (!prev || !prev.section) continue;
                if (prev.section.querySelector('.notes-panel-edit-textarea')) continue;
                prev.section.classList.add('collapsed');
            }
        } else {
            section.classList.add('collapsed');
        }

        const entry = {
            section: section,
            headerEl: headerEl,
            bodyEl: bodyEl,
            tailEl: tailEl,
            countEl: headerEl.querySelector('.notes-panel-chapter-count'),
        };
        chapterSectionsCurrent[ci] = entry;
        installAddRow(entry, lang_id, ci);
        renderChapterStartUserNotes(entry, lang_id, ci);
        return entry;
    }

    function bumpChapterCount(entry) {
        if (!entry || !entry.countEl) return;
        const cur = parseInt(entry.countEl.textContent, 10) || 0;
        entry.countEl.textContent = String(cur + 1);
    }

    function applyViewToggleState() {
        const btns = document.querySelectorAll('.notes-panel-view-btn');
        btns.forEach(function (b) {
            const active = b.getAttribute('data-mode') === currentViewMode;
            b.classList.toggle('active', active);
            b.setAttribute('aria-selected', String(active));
        });
        const panel = document.getElementById('notesPanel');
        if (panel) panel.dataset.viewMode = currentViewMode;
    }

    function setViewMode(mode) {
        const next = (mode === 'original') ? 'original' : 'edited';
        if (next === currentViewMode) return;
        flushActiveEditor();
        currentViewMode = next;
        try { localStorage.setItem(VIEW_MODE_STORAGE_KEY, next); } catch (e) {}
        applyViewToggleState();
        rebuildCurrentLang();
    }

    function flushActiveEditor() {
        const ta = document.querySelector('.notes-panel-edit-textarea');
        if (!ta) return false;
        try {
            const handler = ta._flushHandler;
            if (typeof handler === 'function') handler(true /* keepOpen */);
        } catch (e) {}
        return true;
    }

    function rebuildCurrentLang() {
        if (!currentRenderedLang) return;
        const body = document.getElementById('notesPanelBody');
        if (!body) return;
        body.innerHTML = '';
        chapterSectionsCurrent = {};
        const notes = notesStoreByLang[currentRenderedLang] || [];
        bulkRendering = true;
        try {
            for (let i = 0; i < notes.length; i++) renderNoteToDom(notes[i]);
            installOrphanUserNotes(currentRenderedLang);
        } finally {
            bulkRendering = false;
        }
        body.scrollTop = body.scrollHeight;
    }

    // ----- Panel DOM creation -------------------------------------------------

    function ensurePanel() {
        if (panelInitialized) return;
        // Script runs from <head>; body may not exist yet. Bail and let
        // maybeInitEagerly (DOMContentLoaded) render buffered notes.
        if (!document.body) return;
        panelInitialized = true;

        ensureGlobalSummaryBanner();

        if (!(window.notesEnabled === true || window.notesEnabled === 'true')) return;

        const tab = document.createElement('div');
        tab.id = 'notesPanelTab';
        tab.className = 'notes-panel-tab';
        tab.innerHTML =
            '<span class="notes-panel-tab-label">\ud83d\udcdd Notes</span>' +
            '<span class="notes-panel-tab-badge" style="display:none">0</span>';
        tab.addEventListener('click', function () { setExpanded(true); });

        const panel = document.createElement('aside');
        panel.id = 'notesPanel';
        panel.className = 'notes-panel';
        panel.innerHTML =
            '<div class="notes-panel-resize-handle" id="notesPanelResizeHandle" title="Drag to resize"></div>' +
            '<div class="notes-panel-header">' +
            '  <span class="notes-panel-title">Notes <span class="notes-panel-icon">\u270f</span></span>' +
            '  <div class="notes-panel-view-toggle" role="tablist" aria-label="Notes view">' +
            '    <button type="button" class="notes-panel-view-btn" data-mode="edited" role="tab">Edited</button>' +
            '    <button type="button" class="notes-panel-view-btn" data-mode="original" role="tab">Original</button>' +
            '  </div>' +
            '  <button type="button" class="notes-panel-autoscroll" title="Toggle auto-scroll" aria-pressed="true">\u2913</button>' +
            '  <button type="button" class="notes-panel-close" title="Collapse" aria-label="Collapse notes panel">\u00d7</button>' +
            '</div>' +
            '<div class="notes-panel-body" id="notesPanelBody"></div>' +
            '<button type="button" class="notes-panel-jump" id="notesPanelJump" style="display:none">Jump to latest \u2193</button>';

        panel.querySelector('.notes-panel-close')
            .addEventListener('click', function () { setExpanded(false); });

        const autoBtn = panel.querySelector('.notes-panel-autoscroll');
        autoBtn.addEventListener('click', function () {
            const on = autoBtn.getAttribute('aria-pressed') === 'true';
            autoBtn.setAttribute('aria-pressed', String(!on));
            autoBtn.style.opacity = on ? '0.4' : '1';
        });

        const viewBtns = panel.querySelectorAll('.notes-panel-view-btn');
        viewBtns.forEach(function (btn) {
            btn.addEventListener('click', function () {
                const mode = btn.getAttribute('data-mode');
                setViewMode(mode);
            });
        });
        applyViewToggleState();

        const body = panel.querySelector('.notes-panel-body');
        body.addEventListener('scroll', function () {
            const atBottom = (body.scrollHeight - body.clientHeight) - body.scrollTop < 4;
            const jump = panel.querySelector('#notesPanelJump');
            if (jump) jump.style.display = atBottom ? 'none' : 'block';
        });
        panel.querySelector('#notesPanelJump').addEventListener('click', function () {
            body.scrollTop = body.scrollHeight;
        });

        document.body.appendChild(tab);
        document.body.appendChild(panel);

        applyWidth(loadWidth());
        installResizeHandle(panel);

        applyExpanded();
    }

    function installResizeHandle(panel) {
        const handle = panel.querySelector('#notesPanelResizeHandle');
        if (!handle) return;

        let dragging = false;

        function onMove(e) {
            if (!dragging) return;
            // Panel is right-anchored: width = viewport - clientX.
            const x = (e.touches && e.touches[0]) ? e.touches[0].clientX : e.clientX;
            const w = window.innerWidth - x;
            applyWidth(w);
        }

        function onUp() {
            if (!dragging) return;
            dragging = false;
            document.body.classList.remove('notes-panel-resizing');
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onUp);
            document.removeEventListener('touchmove', onMove);
            document.removeEventListener('touchend', onUp);
            const cur = getComputedStyle(document.documentElement)
                .getPropertyValue('--notes-panel-width').trim();
            const n = parseInt(cur, 10);
            if (isFinite(n)) storeWidth(n);
        }

        function onDown(e) {
            dragging = true;
            document.body.classList.add('notes-panel-resizing');
            document.addEventListener('mousemove', onMove);
            document.addEventListener('mouseup', onUp);
            document.addEventListener('touchmove', onMove, { passive: true });
            document.addEventListener('touchend', onUp);
            e.preventDefault();
        }

        handle.addEventListener('mousedown', onDown);
        handle.addEventListener('touchstart', onDown, { passive: false });
        handle.addEventListener('dblclick', function () {
            applyWidth(DEFAULT_WIDTH);
            storeWidth(DEFAULT_WIDTH);
        });
    }

    function ensureGlobalSummaryBanner() {
        if (document.getElementById('globalSummaryBanner')) return;
        const banner = document.createElement('div');
        banner.id = 'globalSummaryBanner';
        banner.className = 'global-summary-banner';
        banner.style.display = 'none';
        banner.innerHTML =
            '<div class="global-summary-banner-header">' +
            '  <span class="global-summary-banner-title">\ud83d\udcdd Session Summary</span>' +
            '  <button type="button" class="global-summary-banner-toggle" aria-expanded="true" title="Collapse / Expand">\u25be</button>' +
            '</div>' +
            '<div class="global-summary-banner-body" id="globalSummaryBannerBody"></div>';

        const toggle = banner.querySelector('.global-summary-banner-toggle');
        toggle.addEventListener('click', function () {
            const expanded = toggle.getAttribute('aria-expanded') === 'true';
            toggle.setAttribute('aria-expanded', String(!expanded));
            const body = banner.querySelector('.global-summary-banner-body');
            if (body) body.style.display = expanded ? 'none' : 'block';
            toggle.textContent = expanded ? '\u25b8' : '\u25be';
        });

        const main = document.querySelector('main.main-content') || document.body;
        main.insertBefore(banner, main.firstChild);
    }

    function applyExpanded() {
        const panel = document.getElementById('notesPanel');
        const tab = document.getElementById('notesPanelTab');
        if (!panel || !tab) return;
        if (panelExpanded) {
            panel.classList.add('expanded');
            tab.classList.remove('visible');
            document.body.classList.add('notes-panel-expanded');
        } else {
            panel.classList.remove('expanded');
            tab.classList.add('visible');
            document.body.classList.remove('notes-panel-expanded');
        }
    }

    function setExpanded(v) {
        panelExpanded = !!v;
        storeExpanded(panelExpanded);
        applyExpanded();
        if (panelExpanded) clearUnread();
    }

    function clearUnread() {
        const tab = document.getElementById('notesPanelTab');
        if (!tab) return;
        const badge = tab.querySelector('.notes-panel-tab-badge');
        if (badge) {
            badge.style.display = 'none';
            badge.textContent = '0';
        }
    }

    function bumpUnread() {
        if (panelExpanded) return;
        const tab = document.getElementById('notesPanelTab');
        if (!tab) return;
        const badge = tab.querySelector('.notes-panel-tab-badge');
        if (!badge) return;
        const n = (parseInt(badge.textContent, 10) || 0) + 1;
        badge.textContent = String(n);
        badge.style.display = 'inline-block';
    }

    // ----- Per-language buffer + render ---------------------------------------

    function appendNote(lang_id, seq, start, end, nested_level, chapter_index) {
        const key = String(lang_id);
        if (!notesStoreByLang[key]) notesStoreByLang[key] = [];

        // Message's chapter_index is authoritative (survives replay); counter is a fallback.
        let ci = parseInt(chapter_index, 10);
        if (!Number.isFinite(ci) || ci <= 0) {
            ci = chapterIndexByLang[key] || 1;
        }

        const note = {
            seq: String(seq || ''),
            start: start,
            end: end,
            level: (parseInt(nested_level, 10) || 0) >= 1 ? 1 : 0,
            chapterIdx: ci,
        };
        notesStoreByLang[key].push(note);

        ensurePanel();
        if (!panelInitialized) return;  // buffered until maybeInitEagerly

        // First note: setRenderedLang re-renders the buffer; do NOT also
        // call renderNoteToDom below or this note renders twice.
        if (currentRenderedLang === null) {
            const active = getActiveLangId();
            if (active != null) {
                setRenderedLang(active);
                if (currentRenderedLang === key && !panelExpanded) bumpUnread();
                return;
            }
        }

        if (currentRenderedLang === key) {
            renderNoteToDom(note);
            if (!panelExpanded) bumpUnread();
        }
    }

    function renderNoteToDom(note) {
        const body = document.getElementById('notesPanelBody');
        if (!body) return;
        const lang_id = currentRenderedLang;
        const ci = note.chapterIdx;

        const entry = ensureChapterSection(lang_id, ci);
        if (!entry) return;

        const noteId = getNoteId(note);
        const editState = currentViewMode === 'edited' ? getEditState(lang_id, noteId) : null;

        // Deleted: hide, but still count so the header tally matches the
        // original automated total.
        if (editState && editState.deleted) {
            bumpChapterCount(entry);
            return;
        }

        const isEdited = !!(editState && editState.editedText);
        const displayText = isEdited ? editState.editedText : note.seq;

        const noteEl = createNoteElement({
            kind: 'auto',
            noteId: noteId,
            level: note.level,
            start: note.start,
            text: displayText,
            rawText: note.seq,
            isEdited: isEdited,
            editable: currentViewMode === 'edited',
            lang_id: lang_id,
        });
        entry.bodyEl.insertBefore(noteEl, entry.tailEl);
        bumpChapterCount(entry);

        // Splice in any user notes anchored to this auto note.
        if (currentViewMode === 'edited') {
            const userNotes = userNotesForChapter(lang_id, ci);
            for (const u of userNotes) {
                if (u.insertedAfter !== noteId) continue;
                if (entry.bodyEl.querySelector('[data-item-id="' + u.id + '"]')) continue;
                const el = createUserNoteElement(u, lang_id);
                entry.bodyEl.insertBefore(el, entry.tailEl);
            }
        }

        if (bulkRendering) return;

        const autoBtn = document.querySelector('.notes-panel-autoscroll');
        const autoOn = !autoBtn || autoBtn.getAttribute('aria-pressed') === 'true';
        const atBottom = (body.scrollHeight - body.clientHeight) - body.scrollTop < 60;
        if (autoOn && atBottom) {
            body.scrollTop = body.scrollHeight;
        } else {
            const jump = document.getElementById('notesPanelJump');
            if (jump) jump.style.display = 'block';
        }
    }

    // ----- Edit-overlay rendering helpers -------------------------------------

    function createNoteElement(opts) {
        const bulletGlyph = opts.level === 1 ? '\u25e6' : '\u2022';
        const noteEl = document.createElement('div');
        const classes = ['notes-panel-note', 'level-' + opts.level];
        if (opts.kind === 'user') classes.push('user-added');
        if (opts.isEdited) classes.push('edited');
        noteEl.className = classes.join(' ');
        noteEl.dataset.kind = opts.kind;
        if (opts.kind === 'auto') {
            noteEl.dataset.itemId = opts.noteId;
            noteEl.setAttribute('data-start', String(opts.start));
        } else {
            noteEl.dataset.itemId = opts.id;
        }

        const cleaned = String(opts.text || '')
            .replace(/^\s*(?:[\u2022\u25e6]\s*|[-*][ \t]+)/, '')
            .trim();
        const textHtml = (typeof window.applyMD === 'function')
            ? window.applyMD(cleaned)
            : escapeHtml(cleaned);

        const showTime = opts.kind === 'auto' && opts.start != null;
        const timeHtml = showTime ? ('<span class="notes-panel-time" title="Jump to transcript">' + formatTime(opts.start) + '</span>') : '';
        const penHtml = opts.isEdited ? '<span class="notes-panel-pen" title="Edited">✎</span>' : '';
        const deleteHtml = opts.editable ? '<button type="button" class="notes-panel-delete" title="Delete" aria-label="Delete note">×</button>' : '';

        noteEl.innerHTML =
            '<span class="notes-panel-bullet">' + bulletGlyph + '</span>' +
            '<span class="notes-panel-text">' + textHtml + '</span>' +
            penHtml +
            deleteHtml +
            timeHtml;

        const startVal = opts.start;
        function jump(e) {
            if (e) e.stopPropagation();
            if (opts.kind === 'auto' && startVal != null) scrollTranscriptToStart(startVal);
        }

        if (opts.kind === 'auto' && startVal != null) {
            const bulletEl = noteEl.querySelector('.notes-panel-bullet');
            if (bulletEl) bulletEl.addEventListener('click', jump);
            const timeEl = noteEl.querySelector('.notes-panel-time');
            if (timeEl) timeEl.addEventListener('click', jump);
        }

        if (opts.editable) {
            const textEl = noteEl.querySelector('.notes-panel-text');
            textEl.addEventListener('click', function (e) {
                e.stopPropagation();
                openEditor(noteEl, opts);
            });
            const delBtn = noteEl.querySelector('.notes-panel-delete');
            if (delBtn) delBtn.addEventListener('click', function (e) {
                e.stopPropagation();
                handleDelete(noteEl, opts);
            });
        } else if (opts.kind === 'auto' && startVal != null) {
            noteEl.addEventListener('click', jump);
        }

        return noteEl;
    }

    function createUserNoteElement(u, lang_id) {
        return createNoteElement({
            kind: 'user',
            id: u.id,
            level: u.level,
            text: u.text,
            isEdited: false,
            editable: true,
            lang_id: lang_id,
        });
    }

    function installAddRow(entry, lang_id, ci) {
        if (!entry || !entry.tailEl) return;
        entry.tailEl.innerHTML = '';
        if (currentViewMode !== 'edited') return;

        const addRow = document.createElement('div');
        addRow.className = 'notes-panel-add-note';
        addRow.innerHTML =
            '<span class="notes-panel-add-note-glyph">+</span>' +
            '<span class="notes-panel-add-note-label">Add note</span>';
        addRow.addEventListener('click', function () {
            openAddRow(entry, lang_id, ci);
        });
        entry.tailEl.appendChild(addRow);
    }

    function renderChapterStartUserNotes(entry, lang_id, ci) {
        if (!entry || currentViewMode !== 'edited') return;
        const userNotes = userNotesForChapter(lang_id, ci);
        for (const u of userNotes) {
            if (u.insertedAfter != null) continue;
            if (entry.bodyEl.querySelector('[data-item-id="' + u.id + '"]')) continue;
            const el = createUserNoteElement(u, lang_id);
            entry.bodyEl.insertBefore(el, entry.tailEl);
        }
    }

    // Fallback for user notes whose anchor no longer exists (deleted/stale).
    function installOrphanUserNotes(lang_id) {
        if (currentViewMode !== 'edited') return;
        for (const k of Object.keys(chapterSectionsCurrent)) {
            const ci = parseInt(k, 10);
            const entry = chapterSectionsCurrent[k];
            if (!entry) continue;
            const userNotes = userNotesForChapter(lang_id, ci);
            for (const u of userNotes) {
                if (entry.bodyEl.querySelector('[data-item-id="' + u.id + '"]')) continue;
                const el = createUserNoteElement(u, lang_id);
                entry.bodyEl.insertBefore(el, entry.tailEl);
            }
        }
    }

    function attachAutoGrow(ta) {
        function grow() {
            ta.style.height = 'auto';
            ta.style.height = ta.scrollHeight + 'px';
        }
        ta.addEventListener('input', grow);
        grow();
    }

    function openEditor(noteEl, opts) {
        if (noteEl.classList.contains('editing')) return;
        flushActiveEditor();

        const lang_id = opts.lang_id;
        const textEl = noteEl.querySelector('.notes-panel-text');
        if (!textEl) return;

        let source;
        if (opts.kind === 'auto') {
            const st = getEditState(lang_id, opts.noteId);
            source = (st && st.editedText) ? st.editedText : opts.rawText;
        } else {
            const data = loadEdits(lang_id);
            const found = data.userAdded.find(function (n) { return n.id === opts.id; });
            source = found ? found.text : '';
        }

        const ta = document.createElement('textarea');
        ta.className = 'notes-panel-edit-textarea';
        ta.value = String(source || '');
        textEl.style.display = 'none';
        textEl.parentNode.insertBefore(ta, textEl);
        noteEl.classList.add('editing');

        function save(keepOpen) {
            const v = ta.value;
            if (opts.kind === 'auto') {
                setEditedText(lang_id, opts.noteId, v);
            } else {
                updateUserNote(lang_id, opts.id, v);
            }
            if (keepOpen) return;
            close(true);
        }
        function close(rerender) {
            ta.removeEventListener('blur', onBlur);
            ta.removeEventListener('keydown', onKey);
            if (rerender) rerenderSingleNote(noteEl, opts);
            else {
                ta.remove();
                textEl.style.display = '';
                noteEl.classList.remove('editing');
            }
        }
        function onBlur() { save(false); }
        function onKey(e) {
            if (e.key === 'Escape') { e.preventDefault(); close(false); }
            else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); save(false); }
        }

        ta.addEventListener('blur', onBlur);
        ta.addEventListener('keydown', onKey);
        ta._flushHandler = save;

        ta.focus();
        try { ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
        attachAutoGrow(ta);
    }

    function rerenderSingleNote(oldEl, opts) {
        const lang_id = opts.lang_id;
        let newOpts;
        if (opts.kind === 'auto') {
            const st = getEditState(lang_id, opts.noteId);
            const isEdited = !!(st && st.editedText);
            const displayText = isEdited ? st.editedText : opts.rawText;
            newOpts = Object.assign({}, opts, { text: displayText, isEdited: isEdited });
        } else {
            const data = loadEdits(lang_id);
            const found = data.userAdded.find(function (n) { return n.id === opts.id; });
            if (!found) { oldEl.remove(); return; }
            newOpts = Object.assign({}, opts, { text: found.text });
        }
        const newEl = createNoteElement(newOpts);
        oldEl.replaceWith(newEl);
    }

    function handleDelete(noteEl, opts) {
        const lang_id = opts.lang_id;
        if (opts.kind === 'auto') {
            markDeleted(lang_id, opts.noteId, true);
        } else {
            removeUserNote(lang_id, opts.id);
        }
        noteEl.remove();
    }

    function openAddRow(entry, lang_id, ci) {
        flushActiveEditor();
        const addRow = entry.tailEl.querySelector('.notes-panel-add-note');
        if (!addRow) return;

        const ta = document.createElement('textarea');
        ta.className = 'notes-panel-edit-textarea notes-panel-add-note-textarea';
        ta.placeholder = 'New note (use **bold**, *italic*, `code`)';
        ta.rows = 1;
        addRow.style.display = 'none';
        entry.tailEl.insertBefore(ta, addRow);

        function save(keepOpen) {
            const v = ta.value;
            let added = null;
            if (v && v.trim()) {
                // Anchor user note to the last auto note (or null for empty chapter).
                const autoEls = entry.bodyEl.querySelectorAll('.notes-panel-note[data-kind="auto"]');
                const lastAuto = autoEls.length ? autoEls[autoEls.length - 1] : null;
                const insertedAfter = lastAuto ? (lastAuto.dataset.itemId || null) : null;
                added = addUserNote(lang_id, ci, v, 0, insertedAfter);
            }
            if (keepOpen) return;
            cleanup();
            if (added) {
                const el = createUserNoteElement(added, lang_id);
                entry.bodyEl.insertBefore(el, entry.tailEl);
            }
        }
        function cleanup() {
            ta.removeEventListener('blur', onBlur);
            ta.removeEventListener('keydown', onKey);
            ta.remove();
            addRow.style.display = '';
        }
        function onBlur() { save(false); }
        function onKey(e) {
            if (e.key === 'Escape') { e.preventDefault(); cleanup(); }
            else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); save(false); }
        }

        ta.addEventListener('blur', onBlur);
        ta.addEventListener('keydown', onKey);
        ta._flushHandler = save;
        ta.focus();
        attachAutoGrow(ta);
    }

    function setRenderedLang(lang_id) {
        const key = String(lang_id);
        if (currentRenderedLang === key) return;
        flushActiveEditor();
        currentRenderedLang = key;
        ensurePanel();
        rebuildCurrentLang();

        const summary = globalSummaryByLang[key];
        const banner = document.getElementById('globalSummaryBanner');
        const bbody = document.getElementById('globalSummaryBannerBody');
        if (banner && bbody) {
            if (summary) {
                if (typeof window.applyMD === 'function') {
                    bbody.innerHTML = window.applyMD(summary);
                } else {
                    bbody.textContent = summary;
                }
                banner.style.display = 'block';
            } else {
                banner.style.display = 'none';
            }
        }

        clearUnread();
    }

    // syncLangVisible is called lexically in the page script (not via window),
    // so we observe its body.dataset mirror instead of wrapping the function.
    let langObserver = null;
    function installLangObserver() {
        if (langObserver) return;
        if (typeof MutationObserver !== 'function') return;
        if (!document.body) return;
        langObserver = new MutationObserver(function () {
            try {
                const active = getActiveLangId();
                if (active != null && active !== currentRenderedLang) {
                    setRenderedLang(active);
                }
            } catch (e) {
                console.error('NotesPanel: lang observer callback failed', e);
            }
        });
        langObserver.observe(document.body, {
            attributes: true,
            attributeFilter: ['data-lang-visible'],
        });
    }

    // ----- Global summary -----------------------------------------------------

    function getGlobalSummary(lang_id) {
        return globalSummaryByLang[String(lang_id)] || '';
    }

    function showGlobalSummary(lang_id, seq) {
        const key = String(lang_id);
        globalSummaryByLang[key] = String(seq || '');

        ensurePanel();
        if (!panelInitialized) return;

        if (currentRenderedLang === null) {
            const active = getActiveLangId();
            if (active != null) setRenderedLang(active);
        }

        if (currentRenderedLang !== key) return;

        const banner = document.getElementById('globalSummaryBanner');
        if (!banner) return;
        const body = document.getElementById('globalSummaryBannerBody');
        if (!body) return;
        if (typeof window.applyMD === 'function') {
            body.innerHTML = window.applyMD(globalSummaryByLang[key]);
        } else {
            body.textContent = globalSummaryByLang[key];
        }
        banner.style.display = 'block';
    }

    // ----- Chapter signals ----------------------------------------------------

    function onChapterBreak(lang_id, break_start) {
        const key = String(lang_id);
        const breakT = parseFloat(break_start);
        const lastT = lastBreakStartByLang[key];
        if (!isNaN(breakT) && lastT != null && Math.abs(breakT - lastT) < 0.01) {
            return;
        }
        if (!isNaN(breakT)) {
            lastBreakStartByLang[key] = breakT;
            if (!chapterBreakTimesByLang[key]) chapterBreakTimesByLang[key] = [];
            chapterBreakTimesByLang[key].push(breakT);
        }
        const oldChapter = chapterIndexByLang[key] || 1;
        const newChapter = oldChapter + 1;
        chapterIndexByLang[key] = newChapter;

        // Retroactive reshuffle: a break can fire after notes past breakT have
        // already arrived tagged with the old chapter — retag them.
        let moved = false;
        if (!isNaN(breakT)) {
            const buf = notesStoreByLang[key] || [];
            for (const note of buf) {
                if (note.chapterIdx === oldChapter && parseFloat(note.start) >= breakT) {
                    note.chapterIdx = newChapter;
                    moved = true;
                }
            }
        }

        if (moved && currentRenderedLang === key) {
            flushActiveEditor();
            rebuildCurrentLang();
        }
    }

    function onChapterHeading(lang_id, title, start) {
        const t = (title || '').trim();
        if (!t) return;
        const key = String(lang_id);

        // Headings arrive AFTER their chapterBreak fired, so chapterIndexByLang
        // has already advanced. Map start time → chapter via the break-time list.
        const startT = parseFloat(start);
        let ci;
        if (isFinite(startT)) {
            const breaks = chapterBreakTimesByLang[key] || [];
            ci = 1;
            for (let i = 0; i < breaks.length; i++) {
                if (startT < breaks[i]) break;
                ci++;
            }
        } else {
            ci = chapterIndexByLang[key] || 1;
        }

        if (!chapterTitleByLang[key]) chapterTitleByLang[key] = {};
        chapterTitleByLang[key][ci] = t;

        if (currentRenderedLang === key) {
            const entry = chapterSectionsCurrent[ci];
            if (entry && entry.headerEl) {
                const labelEl = entry.headerEl.querySelector('.notes-panel-chapter-label');
                if (labelEl) labelEl.textContent = formatChapterLabel(t, ci);
            }
        }
    }

    // ----- Public surface + init ----------------------------------------------

    window.NotesPanel = {
        appendNote: appendNote,
        showGlobalSummary: showGlobalSummary,
        getGlobalSummary: getGlobalSummary,
        onChapterBreak: onChapterBreak,
        onChapterHeading: onChapterHeading,
        setExpanded: setExpanded,
    };

    function maybeInitEagerly() {
        if (window.notesEnabled === true || window.notesEnabled === 'true') {
            ensurePanel();
        }
        installLangObserver();
        const active = getActiveLangId();
        if (active != null) setRenderedLang(active);
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', maybeInitEagerly);
    } else {
        maybeInitEagerly();
    }
})();
