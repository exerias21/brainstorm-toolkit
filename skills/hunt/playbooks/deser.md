# Playbook: deser — unsafe deserialization

## What this hunts

Code that hydrates objects from attacker-controlled bytes using a
deserializer that can construct arbitrary classes or invoke arbitrary
methods during reconstruction. The classic outcome is RCE; lesser
outcomes include type confusion and authentication bypass.

## Sweep targets

| Language | Dangerous sink | Safe alternative |
|---|---|---|
| Python | `pickle.loads`, `cPickle.loads`, `dill.loads`, `yaml.load` (without `SafeLoader`), `shelve.open` | `json.loads`, `yaml.safe_load` |
| Node | `node-serialize`, `serialize-javascript` w/ runtime code evaluation, custom code-evaluator on JSON | `JSON.parse` |
| Java | `ObjectInputStream.readObject`, XStream w/o whitelist, SnakeYAML w/o `SafeConstructor`, Jackson w/ default typing enabled | Jackson w/ `disable(MapperFeature.DEFAULT_VIEW_INCLUSION)` + explicit types, Gson |
| Ruby | `Marshal.load`, `YAML.load`, `YAML.unsafe_load` | `JSON.parse`, `YAML.safe_load` |
| PHP | `unserialize` | `json_decode` |
| .NET | `BinaryFormatter`, `NetDataContractSerializer`, `LosFormatter`, `SoapFormatter` | `System.Text.Json`, `DataContractJsonSerializer` |

## Vulnerable shape

```python
# Reading a session cookie or import file with no integrity check:
def load_session(req):
    blob = base64.b64decode(req.cookies["sess"])
    return pickle.loads(blob)          # RCE
```

```java
ObjectInputStream ois = new ObjectInputStream(req.getInputStream());
Object cmd = ois.readObject();         // RCE candidate
```

## Safe shape

- Use a JSON-class serializer with a fixed schema and explicit types.
- If a rich object graph really is needed, sign the blob with HMAC and
  verify the signature *before* deserializing. Even then, prefer JSON.
- For YAML, use the SafeLoader / safe_load variant exclusively.

## Suppression rules

- The byte source is a file the application itself wrote and has not
  left the trust boundary (e.g. local cache from a constant). Even
  then, prefer JSON — file corruption can still cause type confusion.
- The blob is HMAC-verified with a server-side secret *before*
  deserialization (find the verify call, confirm it errors on mismatch).

## Trace direction

Sink-first: list every dangerous deserialization call. Trace its byte
source backwards. If the bytes can come from a request body, query,
header, cookie, message queue, uploaded file, or DB row controllable
by the user — confidence is 10. If the source is unclear, drop to 8
but keep the finding.

## Fix vocabulary

"Replace `<dangerous>` with `<safe>` and bind to an explicit DTO/schema."
For Java, name the gadget-chain risk (commons-collections, etc.) — the
mitigation is the deserialization itself, not blocking specific gadgets.
