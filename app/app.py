import os
import json
import boto3
from flask import Flask, request, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool

# 1. Initialize AWS Secrets Manager client & fetch DB credentials
session = boto3.session.Session(region_name=os.getenv('AWS_REGION'))
sm_client = session.client('secretsmanager')
secret_response = sm_client.get_secret_value(SecretId=os.getenv('DB_SECRET_ARN'))
secret = json.loads(secret_response['SecretString'])

# 2. Set up PostgreSQL Connection Pool with RDS CA certificate for SSL
db_pool = ThreadedConnectionPool(
    minconn=1,
    maxconn=10,
    host=os.getenv('DB_HOST'),
    database=os.getenv('DB_NAME'),
    user=secret['username'],
    password=secret['password'],
    sslmode='verify-full',
    sslrootcert='/opt/notes/rds-ca.pem'
)

# 3. Initialize Flask application
app = Flask(__name__)

@app.route('/api/health', methods=['GET'])
def health():
    return 'ok', 200

@app.route('/api/notes', methods=['GET'])
def get_notes():
    conn = db_pool.getconn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute('SELECT * FROM notes ORDER BY updated_at DESC')
            notes = cursor.fetchall()
            return jsonify(notes), 200
    finally:
        db_pool.putconn(conn)

@app.route('/api/notes', methods=['POST'])
def create_note():
    data = request.get_json()
    title = data.get('title')
    body = data.get('body')
    
    conn = db_pool.getconn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                'INSERT INTO notes(title, body) VALUES(%s, %s) RETURNING *',
                (title, body)
            )
            note = cursor.fetchone()
            conn.commit()
            return jsonify(note), 201
    finally:
        db_pool.putconn(conn)

@app.route('/api/notes/<int:note_id>', methods=['PUT'])
def update_note(note_id):
    data = request.get_json()
    title = data.get('title')
    body = data.get('body')
    
    conn = db_pool.getconn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                'UPDATE notes SET title=%s, body=%s, updated_at=now() WHERE id=%s RETURNING *',
                (title, body, note_id)
            )
            note = cursor.fetchone()
            conn.commit()
            return jsonify(note), 200
    finally:
        db_pool.putconn(conn)

@app.route('/api/notes/<int:note_id>', methods=['DELETE'])
def delete_note(note_id):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cursor:
            cursor.execute('DELETE FROM notes WHERE id=%s', (note_id,))
            conn.commit()
            return '', 204
    finally:
        db_pool.putconn(conn)

if __name__ == '__main__':
    port = int(os.getenv('PORT', 3000))
    app.run(host='0.0.0.0', port=port)