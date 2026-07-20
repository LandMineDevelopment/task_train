#!/bin/bash
# postgres-on.sh - Start and enable PostgreSQL

echo "Starting PostgreSQL..."

sudo systemctl start postgresql
sudo systemctl enable postgresql

echo "PostgreSQL status:"
sudo systemctl status postgresql --no-pager -l | head -n 10
