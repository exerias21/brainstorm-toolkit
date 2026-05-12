# Playbook: file-upload — upload validation, traversal, polyglot

## What this hunts

File-upload handlers and the storage path they write to. Three sub-
classes, each with distinct fixes:

1. **Path traversal**: filename derived from input lands outside the
   intended directory (`../../etc/passwd`).
2. **Content-type / extension bypass**: server trusts the client-
   supplied MIME or extension; attacker uploads `.php` / `.aspx` /
   `.svg-with-script` and gets it served.
3. **Polyglot / content disposition**: file is both a valid image and
   a valid HTML/JS file; depending on how it's served, the browser
   may execute it.

## Sweep targets

### Upload entry points
- Multipart parsers: `multer`, `formidable`, `Werkzeug FileStorage`,
  `Spring MultipartFile`, `ActionDispatch::Http::UploadedFile`,
  `pyramid.request.POST`, custom raw `Content-Type: multipart/form-data`
  handlers.

### Filename usage
- Anywhere `filename`, `originalname`, `original_filename`, or the
  client-supplied `Content-Disposition` filename is used to construct a
  disk path.
- `os.path.join(`, `Path(`, `path.join(`, `File.join(` with a user-
  derived component.

### Type checks
- `mimetypes.guess_type(`, `file.mimetype`, `file.contentType`,
  `req.file.mimetype` — these come from the client, do not trust them.
- Magic-byte sniffing: `python-magic`, `file-type`, `Tika`, `mmmagic`
  — these inspect the actual content, can be trusted.

### Storage path
- `media/`, `public/`, `static/`, `wwwroot/`, S3 bucket writes where
  the file ends up at a predictable URL.

## Vulnerable shape

```python
@app.post("/upload")
def upload():
    f = request.files["file"]
    f.save(os.path.join("uploads", f.filename))   # filename can be ../../etc/x
    return {"ok": True}
```

```javascript
const upload = multer({ dest: "public/" });   // served as static
app.post("/avatar", upload.single("img"), (req, res) => {
  // attacker uploads shell.php, fetches /public/shell.php
});
```

## Safe shape

- **Name files server-side**. `uuid4() + extension_from_magic_bytes`.
  Never use any part of the client filename in the storage path.
- **Sniff content type from bytes**, then map to a safe extension
  allowlist (`{jpg, png, gif, webp, pdf}`).
- **Store outside the web root**. Serve via an authenticated handler
  that sets `Content-Type` and `Content-Disposition: attachment` for
  anything not on an inline-safe allowlist.
- **Strip SVG to text-only DOMPurify-equivalent**, or just refuse SVG
  uploads — they're HTML in disguise.

## Suppression rules

- Filename is `uuid4()` (or equivalent CSPRNG-derived) and the original
  filename is only stored as a *metadata column*, never used in the
  path.
- Storage is an object store served via a signed URL with
  `Content-Disposition: attachment` forced.
- Upload directory is configured to disable script execution at the
  web-server level (e.g., nginx `location /uploads { add_header
  Content-Disposition attachment; }`) AND that config is in this repo
  (cite the file).

## Trace direction

Sink-first: each disk-write site. Trace the filename and path
components backwards. Separately trace the content-type check: is it
trusted from the client, or sniffed from the bytes?

## Fix vocabulary

Bundle three fixes per finding: (a) rename to UUID, (b) magic-byte
sniff with allowlist, (c) serve via authenticated handler outside
web root. Half-fixes leave the door open — call that out in the
recommendation.
