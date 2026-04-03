-- AI Sync Agent — Supabase Schema
-- Enable pgvector extension
create extension if not exists vector;

-- Jira tickets table with vector embeddings
create table if not exists jira_tickets (
  id          bigserial primary key,
  ticket_id   text unique not null,
  title       text not null,
  description text,
  status      text,
  assignee    text,
  project     text,
  url         text,
  embedding   vector(1536),
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- IVFFlat index for fast cosine similarity search
create index if not exists jira_tickets_embedding_idx
  on jira_tickets using ivfflat (embedding vector_cosine_ops)
  with (lists = 50);

-- Semantic search RPC function
-- Returns tickets ranked by cosine similarity to query embedding
create or replace function match_tickets (
  query_embedding vector(1536),
  match_threshold float default 0.3,
  match_count     int   default 5
)
returns table (
  ticket_id   text,
  title       text,
  description text,
  status      text,
  url         text,
  similarity  float
)
language sql stable
as $$
  select
    ticket_id,
    title,
    description,
    status,
    url,
    1 - (embedding <=> query_embedding) as similarity
  from jira_tickets
  where 1 - (embedding <=> query_embedding) > match_threshold
  order by similarity desc
  limit match_count;
$$;
