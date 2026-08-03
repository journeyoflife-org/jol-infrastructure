"""Query endpoint — RAG pipeline access.

POST /query — Retrieve context, generate answer via LLM.
Requires 'analyst' or 'admin' role (RBAC).

SOC 2 CC6.1 — Logical access (authenticated queries only)
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status

from app.audit import get_audit_logger
from app.auth import TokenPayload, require_permission
from app.models import QueryRequest, QueryResponse
from app.services.pipeline import get_pipeline

router = APIRouter(tags=["query"])


@router.post(
    "/query",
    response_model=QueryResponse,
    summary="Query the RAG pipeline",
    description=(
        "Submit a natural language question. The system retrieves relevant "
        "document chunks, constructs a prompt, and generates an answer via "
        "the local LLM (Ollama on llm-prod-lt01). "
        "Requires 'analyst' or 'admin' role."
    ),
    dependencies=[Depends(require_permission("query"))],
)
async def query_rag(
    body: QueryRequest,
    request: Request,
    user: Annotated[TokenPayload, Depends(require_permission("query"))],
) -> QueryResponse:
    """Execute a RAG query: retrieve, augment, generate."""
    audit = get_audit_logger()
    client_ip = getattr(request.state, "client_ip", "unknown")
    pipeline = get_pipeline()

    try:
        response = pipeline.query(
            question=body.question,
            top_k=body.top_k,
            filters=body.filters or None,
            include_sources=body.include_sources,
        )

        # Audit log
        audit.log_event(
            action="query.execute",
            user_id_pseudo=getattr(request.state, "user_id_pseudo", "unknown"),
            resource_id=f"query:{hash(body.question) & 0xFFFFFFFF:08x}",
            client_ip=client_ip,
            outcome="success",
            details={
                "top_k": body.top_k,
                "sources_count": len(response.sources),
                "latency_ms": response.latency_ms,
            },
        )

        return response

    except ConnectionError as exc:
        audit.log_event(
            action="query.execute",
            user_id_pseudo=getattr(request.state, "user_id_pseudo", "unknown"),
            resource_id="query",
            client_ip=client_ip,
            outcome="failure",
            details={"error": "service_unavailable", "detail": str(exc)},
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Backend service temporarily unavailable. Please retry.",
        ) from exc
    except Exception as exc:
        audit.log_event(
            action="query.execute",
            user_id_pseudo=getattr(request.state, "user_id_pseudo", "unknown"),
            resource_id="query",
            client_ip=client_ip,
            outcome="failure",
            details={"error": str(exc)},
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Query processing failed: {exc}",
        ) from exc
