
FROM python:3.13-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install -r requirements.txt

COPY app/app.py .

RUN mkdir /data

USER 1000

EXPOSE 8000

CMD ["python", "app.py"]

