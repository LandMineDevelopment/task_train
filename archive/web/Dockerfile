FROM node:22-bookworm-slim AS frontend
WORKDIR /src
COPY web/frontend/package.json web/frontend/package-lock.json ./
RUN npm ci
COPY web/frontend ./
RUN npm run build

FROM python:3.13-slim
WORKDIR /app
COPY web/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY web/backend/api.py ./api.py
COPY --from=frontend /src/dist ./static
EXPOSE 8000
CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8000"]
