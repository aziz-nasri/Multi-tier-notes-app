const API_BASE = '/api';

// State
let notes = [];
let activeNoteId = null;

// DOM Elements
const statusBadge = document.getElementById('api-status');
const notesListEl = document.getElementById('notes-list');
const searchInput = document.getElementById('search-input');
const newNoteBtn = document.getElementById('new-note-btn');
const noteForm = document.getElementById('note-form');
const noteIdInput = document.getElementById('note-id');
const noteTitleInput = document.getElementById('note-title');
const noteBodyInput = document.getElementById('note-body');
const noteMetaEl = document.getElementById('note-meta');
const deleteBtn = document.getElementById('delete-btn');
const toastEl = document.getElementById('toast');

// Initialize App
document.addEventListener('DOMContentLoaded', () => {
  checkHealth();
  fetchNotes();
});

// Check /api/health
async function checkHealth() {
  try {
    const res = await fetch(`${API_BASE}/health`);
    if (res.ok) {
      statusBadge.textContent = 'API Online';
      statusBadge.className = 'status-badge online';
    } else {
      throw new Error('Health check failed');
    }
  } catch (err) {
    statusBadge.textContent = 'API Offline';
    statusBadge.className = 'status-badge offline';
  }
}

// Fetch all notes: GET /api/notes
async function fetchNotes() {
  try {
    const res = await fetch(`${API_BASE}/notes`);
    if (!res.ok) throw new Error('Failed to load notes');
    notes = await res.json();
    renderNotesList(notes);
  } catch (err) {
    showToast('Error loading notes from server', true);
  }
}

// Render sidebar list
function renderNotesList(notesToRender) {
  notesListEl.innerHTML = '';

  if (notesToRender.length === 0) {
    notesListEl.innerHTML = '<li style="padding: 1rem; color: #64748b; font-size: 0.875rem;">No notes found.</li>';
    return;
  }

  notesToRender.forEach(note => {
    const li = document.createElement('li');
    li.className = `note-item ${note.id === activeNoteId ? 'active' : ''}`;
    li.onclick = () => selectNote(note);

    const dateStr = note.updated_at 
      ? new Date(note.updated_at).toLocaleString() 
      : '';

    li.innerHTML = `
      <div class="note-item-title">${escapeHtml(note.title || 'Untitled')}</div>
      <div class="note-item-preview">${escapeHtml(note.body || '')}</div>
      <div class="note-item-date">${dateStr}</div>
    `;
    notesListEl.appendChild(li);
  });
}

// Load note into editor
function selectNote(note) {
  activeNoteId = note.id;
  noteIdInput.value = note.id;
  noteTitleInput.value = note.title;
  noteBodyInput.value = note.body;
  
  if (note.updated_at) {
    noteMetaEl.textContent = `Last updated: ${new Date(note.updated_at).toLocaleString()}`;
  } else {
    noteMetaEl.textContent = '';
  }

  deleteBtn.classList.remove('hidden');
  renderNotesList(filterNotes(searchInput.value));
}

// Reset editor for a new note
function resetEditor() {
  activeNoteId = null;
  noteIdInput.value = '';
  noteTitleInput.value = '';
  noteBodyInput.value = '';
  noteMetaEl.textContent = 'New note';
  deleteBtn.classList.add('hidden');
  noteTitleInput.focus();
  renderNotesList(filterNotes(searchInput.value));
}

// Create or Update Note: POST /api/notes or PUT /api/notes/<id>
noteForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  
  const id = noteIdInput.value;
  const payload = {
    title: noteTitleInput.value.trim(),
    body: noteBodyInput.value.trim()
  };

  if (!payload.title || !payload.body) return;

  try {
    const isUpdate = Boolean(id);
    const url = isUpdate ? `${API_BASE}/notes/${id}` : `${API_BASE}/notes`;
    const method = isUpdate ? 'PUT' : 'POST';

    const res = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    if (!res.ok) throw new Error('Failed to save note');
    const savedNote = await res.json();

    showToast(isUpdate ? 'Note updated' : 'Note created');
    await fetchNotes();
    selectNote(savedNote);
  } catch (err) {
    showToast('Error saving note', true);
  }
});

// Delete Note: DELETE /api/notes/<id>
deleteBtn.addEventListener('click', async () => {
  const id = noteIdInput.value;
  if (!id || !confirm('Delete this note?')) return;

  try {
    const res = await fetch(`${API_BASE}/notes/${id}`, {
      method: 'DELETE'
    });

    if (!res.ok && res.status !== 204) throw new Error('Failed to delete note');

    showToast('Note deleted');
    resetEditor();
    await fetchNotes();
  } catch (err) {
    showToast('Error deleting note', true);
  }
});

// Search/Filter handler
searchInput.addEventListener('input', (e) => {
  renderNotesList(filterNotes(e.target.value));
});

function filterNotes(query) {
  const q = query.toLowerCase().trim();
  if (!q) return notes;
  return notes.filter(n => 
    (n.title && n.title.toLowerCase().includes(q)) || 
    (n.body && n.body.toLowerCase().includes(q))
  );
}

newNoteBtn.addEventListener('click', resetEditor);

// Helpers
function showToast(message, isError = false) {
  toastEl.textContent = message;
  toastEl.style.background = isError ? '#dc2626' : '#1e293b';
  toastEl.classList.remove('hidden');
  setTimeout(() => toastEl.classList.add('hidden'), 3000);
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}