# AI Sync Agent

> **n8n · Supabase pgvector · OpenAI · Google Chat**

AI agent that automates two Jira workflows:

1. **Done Notification** — when a ticket moves to "Done", automatically sends a GPT-generated summary to Google Chat and Email
2. **Semantic Ticket Search** — natural language search over your entire Jira backlog using vector embeddings (finds meaning, not just keywords)

---

## Why Custom Instead of Atlassian Rovo / Native Jira AI?

Atlassian's built-in AI (Rovo, Atlassian Intelligence) was evaluated first. It was ruled out for three reasons:

- **No public API** — Rovo's semantic search is internal to the Atlassian UI only. There is no endpoint that returns programmatic search results, making it impossible to embed in n8n or any external automation
- **Plan requirement** — Atlassian Intelligence requires Premium or Enterprise Jira plans. This solution works on any tier including Free
- **No action layer** — Rovo answers questions inside the UI. It cannot trigger external notifications, write to other systems, or fire automation workflows based on search results

The custom approach gives full programmatic control: search results come back as structured JSON, can be filtered by SQL alongside semantic similarity, and feed directly into downstream n8n automation.

---

## Architecture

```
Jira (webhook / REST API)
        ↓
  n8n Orchestration
  ├── Part 1: Status = Done → GPT summary → Google Chat + Email
  └── Part 2: Chat query → OpenAI embed → Supabase cosine search → results
        ↓
  Supabase pgvector (jira_tickets table)
        ↓
  OpenAI text-embedding-3-small + GPT-4.1
```

---

## Semantic Search Demo

The assignment spec asks: *"Did we ever fix that weird login lag on mobile?"*

**Live result (execution #7521):**
```
Query:  "Did we ever fix that weird login lag on mobile?"
Match:  [PROJ-101] Optimize OAuth handshake latency
Status: Done | Similarity: 49%
URL:    https://demo.atlassian.net/browse/PROJ-101
```

Zero word overlap between query and ticket title. Pure semantic matching via cosine similarity on 1536-dimension embeddings.

---

## Workflows

| File | Description | n8n ID |
|------|-------------|--------|
| `workflows/ingestion.json` | Fetch Jira tickets → embed → store in Supabase | XdkcFAmALpjdQIO7 |
| `workflows/part1-notification.json` | Jira webhook → Done filter → GPT summary → notify | fQv2hhPSYFZ1GIAi |
| `workflows/part2-search.json` | Chat trigger → embed query → semantic search → results | NERxbZOX3hyWNHIb |

---

## Setup

### 1. Supabase
```bash
# Run schema.sql in your Supabase SQL editor
# Creates: jira_tickets table, ivfflat index, match_tickets() function
```

### 2. n8n Credentials Required
- `OpenAI API` — for embeddings (text-embedding-3-small) and GPT-4.1 summaries
- `Supabase API` — URL + service role key
- `Google Chat Webhook URL` — in the Part 1 workflow node

### 3. Import Workflows
Import each JSON file into n8n via **Settings → Import from file**

### 4. Configure Jira Webhook (Part 1)
In Jira: **Project Settings → Automation → Webhooks**
- URL: `https://your-n8n-instance/webhook/jira-done`
- Events: Issue updated (status change)

### 5. Run Ingestion
Execute the ingestion workflow manually to embed all existing tickets.
For ongoing sync, add a Schedule Trigger (daily recommended).

---

## Edge Cases Handled

| Scenario | Handling |
|----------|----------|
| Empty ticket description | Embeds title only; notification notes "no description" |
| Duplicate webhook fires | Upsert with `on_conflict=ticket_id` — idempotent |
| OpenAI rate limit (429) | n8n automatic retry with backoff |
| No search results above threshold | Returns friendly message, not empty response |
| Garbage / emoji-only text | Skipped if < 10 chars after trim |

---

## Why Supabase pgvector?

Evaluated against Pinecone, Qdrant, and Weaviate. For this use case (10k–100k tickets, low query volume):

- **Single query for semantic + SQL filters** — `WHERE status = 'Done' AND similarity > 0.5` in one Postgres query. Pinecone requires two API calls
- **ACID compliance** — ticket metadata and embeddings always consistent
- **<20ms at 100k vectors** with HNSW index — more than adequate
- **~$35–75/month** — cheapest option at this scale
- **Existing infrastructure** — if Jira data is already in Postgres, pgvector is a natural extension

---

## Time Tracking

| Task | Time |
|------|------|
| Architecture design + diagram | 75 min |
| Supabase schema + match_tickets() | 45 min |
| Workflow A — Ticket ingestion | 45 min |
| Workflow B — Done notification | 60 min |
| Workflow C — Semantic search | 45 min |
| Testing + mock data + semantic search validation | 30 min |
| Written sections + documentation | 45 min |
| **Total** | **~6 hours** |

---

## Potential Next Steps

### 1. Intent Classification Before Search

Currently every message goes straight to vector search. A production bot should first classify intent:

```
User message → GPT classify intent → route
  ├── semantic_search  → embed → cosine search → reply
  ├── structured_query → Jira REST API (list, count, fetch by ID) → reply
  └── unknown          → "I can search your Jira backlog. Try: did we fix X?"
```

This handles queries like "show me all open tickets" or "what is PROJ-101" correctly — those need SQL/REST, not vector search.

### 2. Jira Webhook for Real-time Ingestion

The current ingestion runs on a schedule. A better approach is to also trigger re-embedding whenever a ticket is created or updated in Jira, keeping the vector index fresh in real time.

### 3. Hybrid Search (Semantic + Metadata Filters)

Extend `match_tickets()` to accept structured filters alongside the vector query:

```sql
WHERE status = 'Done'
  AND metadata->>'assignee' = 'sarah'
  AND 1 - (embedding <=> query_embedding) > 0.3
```

This handles queries like "what authentication tickets did Sarah close last month?" — combining semantic meaning with structured constraints in a single query.

### 4. Feedback Loop

Add a thumbs up/down reaction handler in Google Chat. When a user reacts negatively to a result, log the query + result pair to a `search_feedback` table. Use that data to periodically fine-tune the similarity threshold or improve ticket descriptions.