"""
knowledge_base.py — Self-embedded RAG using the chat model itself.

Workflow:
  1. ingest()  — parse Confluence XML (or plain text/md files from a folder),
                 chunk the content, embed each chunk with the loaded model,
                 save everything to a JSON index file.
  2. search()  — embed the user's query, find the top-K closest chunks
                 via cosine similarity, return their text.

No external embedding model, no vector DB. Just the model you already have,
numpy for fast dot products, and a JSON file on disk.

Directory layout:
  server/knowledge/           ← drop your source files here
  server/knowledge_index.json ← auto-generated index (embeddings + text)
"""

import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Dict, Optional
from html.parser import HTMLParser



# ── Config ─────────────────────────────────────────────────────────
KNOWLEDGE_DIR = Path("knowledge")
INDEX_PATH = Path("knowledge_index.json")

CHUNK_SIZE = 1000      # chars per chunk (roughly ~250 tokens)
CHUNK_OVERLAP = 150    # overlap between consecutive chunks
TOP_K = 6              # number of chunks to retrieve per query
MAX_INJECT_CHARS = 4000  # max total chars injected into prompt


# ── HTML stripper ──────────────────────────────────────────────────
class HTMLStripper(HTMLParser):
    """Strip HTML tags from Confluence content, keeping text."""
    def __init__(self):
        super().__init__()
        self.pieces = []

    def handle_data(self, data):
        self.pieces.append(data)

    def get_text(self):
        return " ".join(self.pieces)


def strip_html(html_text: str) -> str:
    s = HTMLStripper()
    s.feed(html_text)
    return s.get_text()


# ── Confluence XML parser ──────────────────────────────────────────
def parse_confluence_xml(xml_path: Path) -> List[Dict[str, str]]:
    """
    Parse a Confluence XML export and extract pages.
    Returns list of {"title": ..., "body": ...} dicts.

    Confluence exports vary in structure. This handles:
      - Standard XML exports with <object> elements of class="Page"
      - Each page has <property name="title"> and <property name="bodyContent">
    """
    pages = []
    try:
        tree = ET.parse(str(xml_path))
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"  ✗ XML parse error in {xml_path.name}: {e}")
        return pages

    # Strategy 1: Confluence XML export format
    for obj in root.iter("object"):
        obj_class = obj.get("class", "")
        if "Page" not in obj_class and "BlogPost" not in obj_class:
            continue

        title = ""
        body = ""
        for prop in obj.findall("property"):
            name = prop.get("name", "")
            if name == "title":
                title = (prop.text or "").strip()
            elif name in ("bodyContent", "body", "content"):
                # Body might be nested in a child element
                body_text = prop.text or ""
                for child in prop:
                    if child.text:
                        body_text += child.text
                    if child.tail:
                        body_text += child.tail
                body = strip_html(body_text).strip()

        if body:
            pages.append({"title": title or "Untitled", "body": body})

    # Strategy 2: simpler XML with <page> elements
    if not pages:
        for page_el in root.iter("page"):
            title = ""
            body = ""
            title_el = page_el.find("title")
            if title_el is not None and title_el.text:
                title = title_el.text.strip()
            body_el = page_el.find("body") or page_el.find("content")
            if body_el is not None:
                raw = body_el.text or ""
                body = strip_html(raw).strip()
            if body:
                pages.append({"title": title or "Untitled", "body": body})

    # Strategy 3: if all else fails, just grab all text content
    if not pages:
        full_text = ET.tostring(root, encoding="unicode", method="text")
        full_text = full_text.strip()
        if full_text:
            pages.append({"title": xml_path.stem, "body": full_text})

    return pages


# ── Text file reader ───────────────────────────────────────────────
def read_text_file(path: Path) -> List[Dict[str, str]]:
    """Read a plain text or markdown file as a single document."""
    try:
        text = path.read_text(encoding="utf-8").strip()
        if text:
            return [{"title": path.stem, "body": text}]
    except Exception as e:
        print(f"  ✗ Could not read {path.name}: {e}")
    return []


# ── HTML file reader ───────────────────────────────────────────────
# Tag/id/class names that are pure boilerplate in Confluence HTML exports.
# Content inside these is skipped entirely during parsing.
_SKIP_TAGS = {"script", "style", "nav", "header", "footer"}
_SKIP_IDS  = {"header", "footer", "sidebar", "comments-section",
               "page-navigation", "breadcrumb-section", "page-children-container"}
_SKIP_CLASSES = {"breadcrumb-section", "page-metadata", "toc-macro",
                 "page-navigation", "confluence-information-macro-body",
                 "page-children-container", "footer", "aui-nav"}

# Content div ids/classes to target — checked in priority order.
# The parser extracts ONLY the first matching region if found.
_CONTENT_IDS     = ["main-content", "content"]
_CONTENT_CLASSES = ["wiki-content", "article-content"]


class ConfluenceHTMLParser(HTMLParser):
    """
    Stdlib-only Confluence-aware HTML parser.

    Two-pass strategy:
      1. First pass: scan for a known content div (main-content, wiki-content…).
         If found, record its byte-level start so we can re-parse just that region.
      2. During text collection: skip entire subtrees whose tag, id, or class
         matches the boilerplate lists above.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.pieces        = []
        self._skip_depth   = 0   # >0 means we are inside a skip subtree
        self._capture      = True

    def _is_skip(self, tag: str, attrs: dict) -> bool:
        if tag in _SKIP_TAGS:
            return True
        el_id = attrs.get("id", "")
        if el_id in _SKIP_IDS:
            return True
        classes = set(attrs.get("class", "").split())
        if classes & _SKIP_CLASSES:
            return True
        return False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if self._skip_depth > 0:
            self._skip_depth += 1
            return
        if self._is_skip(tag, attrs):
            self._skip_depth = 1
            return

    def handle_endtag(self, tag):
        if self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data):
        if self._skip_depth == 0:
            text = data.strip()
            if text:
                self.pieces.append(text)

    def get_text(self) -> str:
        return " ".join(self.pieces)


def _extract_confluence_content(raw: str) -> str:
    """
    Extract just the page body from a Confluence HTML export.

    Strategy:
      1. Try to isolate the content region by id/class using a regex slice
         (avoids parsing the whole document when possible).
      2. Parse that slice (or the full doc as fallback) with ConfluenceHTMLParser,
         which skips boilerplate subtrees.
    """
    # Try to find a content anchor by id
    content_raw = None
    for cid in _CONTENT_IDS:
        m = re.search(rf'<[^>]+id=["\']?{re.escape(cid)}["\']?[^>]*>', raw, re.IGNORECASE)
        if m:
            content_raw = raw[m.end():]
            break

    # Try by class if no id match
    if content_raw is None:
        for cls in _CONTENT_CLASSES:
            m = re.search(rf'<[^>]+class=["\'][^"\']*{re.escape(cls)}[^"\']*["\'][^>]*>', raw, re.IGNORECASE)
            if m:
                content_raw = raw[m.end():]
                break

    parser = ConfluenceHTMLParser()
    parser.feed(content_raw if content_raw is not None else raw)
    return parser.get_text()


def read_html_file(path: Path) -> List[Dict[str, str]]:
    """
    Read a standalone HTML file (e.g. Confluence HTML export).
    Extracts only meaningful page content, discarding nav/header/footer boilerplate.
    """
    try:
        raw = path.read_text(encoding="utf-8").strip()
        if not raw:
            return []

        # Extract and clean title
        title = path.stem
        title_match = re.search(r"<title[^>]*>(.*?)</title>", raw, re.IGNORECASE | re.DOTALL)
        if title_match:
            raw_title = strip_html(title_match.group(1)).strip()
            # Confluence appends " - Space Name - Confluence" to page titles
            raw_title = re.sub(r"\s*[-–]+\s*[^-–]+[-–]+\s*Confluence\s*$",
                               "", raw_title, flags=re.IGNORECASE).strip()
            title = raw_title or title

        body = _extract_confluence_content(raw)
        body = re.sub(r"\s+", " ", body).strip()

        if body:
            return [{"title": title, "body": body}]
    except Exception as e:
        print(f"  ✗ Could not read {path.name}: {e}")
    return []


# ── Chunker ────────────────────────────────────────────────────────
def chunk_text(text: str, title: str = "") -> List[Dict[str, str]]:
    """
    Split text into overlapping chunks.
    Each chunk gets tagged with its source title.
    """
    # Clean up whitespace
    text = re.sub(r"\s+", " ", text).strip()

    if len(text) <= CHUNK_SIZE:
        return [{"title": title, "text": text}]

    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE

        # Try to break at a sentence boundary
        if end < len(text):
            for sep in [". ", ".\n", "\n\n", "\n", " "]:
                last_sep = text.rfind(sep, start + CHUNK_SIZE // 2, end + 50)
                if last_sep > start:
                    end = last_sep + len(sep)
                    break

        chunk_text_str = text[start:end].strip()
        if chunk_text_str:
            prefix = f"[{title}] " if title else ""
            chunks.append({
                "title": title,
                "text": prefix + chunk_text_str,
            })

        start = end - CHUNK_OVERLAP
        if start >= len(text):
            break

    return chunks


# ── Cosine similarity (no numpy required) ─────────────────────────
def _dot(a: list, b: list) -> float:
    return sum(x * y for x, y in zip(a, b))

def _norm(v: list) -> float:
    return math.sqrt(sum(x * x for x in v))

def cosine_similarity(a: list, b: list) -> float:
    na, nb = _norm(a), _norm(b)
    if na == 0 or nb == 0:
        return 0.0
    return _dot(a, b) / (na * nb)


# ── Knowledge Base ─────────────────────────────────────────────────
class KnowledgeBase:
    def __init__(self):
        self._model = None
        self._index: List[Dict] = []   # [{"title", "text", "embedding"}, ...]
        self._ready = False

    def set_model(self, model_loader) -> None:
        self._model = model_loader

    @property
    def ready(self) -> bool:
        return self._ready and len(self._index) > 0

    @property
    def chunk_count(self) -> int:
        return len(self._index)

    def load_index(self) -> bool:
        """Load a previously built index from disk."""
        if not INDEX_PATH.exists():
            return False
        try:
            data = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
            self._index = data.get("chunks", [])
            self._ready = len(self._index) > 0
            if self._ready:
                print(f"  ✓ Knowledge base loaded: {len(self._index)} chunks from index")
            return self._ready
        except Exception as e:
            print(f"  ✗ Could not load knowledge index: {e}")
            return False

    def ingest(self, source_dir: Optional[Path] = None) -> int:
        """
        Ingest all files from the knowledge directory.
        Supports: .xml (Confluence), .md, .txt
        Returns number of chunks created.
        """
        if self._model is None:
            print("  ✗ Cannot ingest: no model set")
            return 0

        src = source_dir or KNOWLEDGE_DIR
        if not src.exists():
            print(f"  ✗ Knowledge directory not found: {src}")
            return 0

        # Collect all documents (recursive — subdirectories supported)
        documents = []
        for f in sorted(src.rglob("*")):
            if not f.is_file():
                continue
            # Show path relative to knowledge dir for clarity
            rel = f.relative_to(src)
            if f.suffix.lower() == ".xml":
                print(f"  📄 Parsing XML: {rel}")
                documents.extend(parse_confluence_xml(f))
            elif f.suffix.lower() in (".md", ".txt"):
                print(f"  📄 Reading: {rel}")
                documents.extend(read_text_file(f))
            elif f.suffix.lower() in (".html", ".htm"):
                print(f"  📄 Reading HTML: {rel}")
                documents.extend(read_html_file(f))
            else:
                print(f"  ⊘ Skipping: {rel}")

        if not documents:
            print("  ✗ No documents found to ingest")
            return 0

        print(f"  → {len(documents)} document(s) found")

        # Chunk all documents
        all_chunks = []
        for doc in documents:
            chunks = chunk_text(doc["body"], doc["title"])
            all_chunks.extend(chunks)

        print(f"  → {len(all_chunks)} chunk(s) created")

        # Embed each chunk
        print(f"  → Embedding chunks (this may take a while)...")
        indexed = []
        for i, chunk in enumerate(all_chunks):
            embedding = self._model.embed(chunk["text"])
            if not embedding:
                print(f"    ⚠ Empty embedding for chunk {i}, skipping")
                continue
            indexed.append({
                "title": chunk["title"],
                "text": chunk["text"],
                "embedding": embedding,
            })
            if (i + 1) % 10 == 0:
                print(f"    … {i + 1}/{len(all_chunks)} embedded")

        print(f"  → {len(indexed)} chunk(s) embedded successfully")

        # Save index
        index_data = {
            "version": 1,
            "source_dir": str(src),
            "chunk_count": len(indexed),
            "chunk_size": CHUNK_SIZE,
            "chunks": indexed,
        }
        INDEX_PATH.write_text(
            json.dumps(index_data, ensure_ascii=False),
            encoding="utf-8",
        )
        print(f"  ✓ Index saved to {INDEX_PATH} ({INDEX_PATH.stat().st_size / 1024:.0f} KB)")

        self._index = indexed
        self._ready = True
        return len(indexed)

    def search(self, query: str, top_k: int = TOP_K) -> List[Dict[str, str]]:
        """
        Search for chunks relevant to the query.
        Returns list of {"title": ..., "text": ..., "score": ...} dicts.
        """
        if not self._ready or not self._index or self._model is None:
            return []

        query_embedding = self._model.embed(query)
        if not query_embedding:
            return []

        # Score all chunks
        scored = []
        for chunk in self._index:
            score = cosine_similarity(query_embedding, chunk["embedding"])
            scored.append({
                "title": chunk["title"],
                "text": chunk["text"],
                "score": score,
            })

        # Sort by score descending, take top K
        scored.sort(key=lambda x: x["score"], reverse=True)
        return scored[:top_k]

    def get_context(self, query: str) -> str:
        """
        Search and format results as a context block for prompt injection.
        Returns empty string if no relevant results found.
        """
        results = self.search(query)
        if not results:
            return ""

        # Filter out very low scores (below 0.3 is usually noise)
        relevant = [r for r in results if r["score"] > 0.3]
        if not relevant:
            return ""

        # Build context block, respecting char limit
        pieces = []
        total = 0
        for r in relevant:
            text = r["text"]
            if total + len(text) > MAX_INJECT_CHARS:
                remaining = MAX_INJECT_CHARS - total
                if remaining > 100:
                    text = text[:remaining] + "…"
                else:
                    break
            pieces.append(text)
            total += len(text)

        if not pieces:
            return ""

        return "REFERENCE MATERIAL (use this to answer if relevant):\n" + "\n---\n".join(pieces) + "\n\n"
