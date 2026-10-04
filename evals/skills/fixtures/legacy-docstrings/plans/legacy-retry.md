## Legacy Retry Loop

Do not reintroduce the naive retry loop around the payments API call: it caused a
thundering-herd incident in production (2024-03-11) when every client retried on the
same fixed backoff simultaneously.
