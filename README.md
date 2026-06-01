# Stockbit/Bibit — Senior Data Engineer Technical Test
**Candidate:** Mohammad Iqbal

---

## Task 1 — Data Pipeline Architecture

Full system design for a GCP analytics platform covering ingestion, storage, transformation, and presentation layers. Includes two solution options (full managed vs cost-optimized) with tradeoff analysis.

📄 **[MOHAMMAD_IQBAL_TASK1_.pdf](https://github.com/iqbalmohamad/stockbit-olist-dwh-test/blob/main/docs/MOHAMMAD_IQBAL_TASK1_.pdf)**

---

## Task 2 — Query & Data Modeling

End-to-end data warehouse implementation using the Olist Brazilian E-Commerce dataset — including data cleansing, Kimball star schema DWH, SQL transformation scripts, DQC checks, and a REST API.

📄 **[MOHAMMAD_IQBAL_TASK2.pdf](https://github.com/iqbalmohamad/stockbit-olist-dwh-test/blob/main/docs/MOHAMMAD_IQBAL_TASK2.pdf)**

### Quick Start

```bash
# 1. Install dependencies
pip install duckdb pyarrow fastapi uvicorn

# 2. Place Olist parquet files in olist_dataset/

# 3. Run pipeline (generates db/olist_dwh.duckdb)
python script/py/run_pipeline.py

# 4. Start API
python script/py/api.py
# → Swagger docs at http://localhost:8000/docs
```

### Repository Structure

```
stockbit-olist-dwh-test/
├── docs/                          # Task 1 and Task 2 PDF submissions
├── db/
│   └── olist_dwh.zip              # Pre-built DuckDB warehouse (unzip to use)
├── olist_dataset/                 # Source Parquet files (place here)
├── script/
│   ├── sql/
│   │   ├── 01_ddl.sql             # DDL — all tables, sequences, dqc_results
│   │   ├── 02_load_dimensions.sql # Idempotent dimension loading (MERGE + SCD2)
│   │   ├── 03_load_facts.sql      # Idempotent fact loading (DELETE + INSERT)
│   │   ├── 04_dim_dqc.sql         # 18 DQC checks for dimensions
│   │   └── 05_fct_dqc.sql         # 17 DQC checks for facts
│   └── py/
│       ├── run_pipeline.py        # Pipeline orchestrator
│       └── api.py                 # FastAPI REST API
└── README.md
```
