#!/bin/bash
# postgres-off.sh - Stop and disable PostgreSQL

echo "Stopping PostgreSQL..."

sudo systemctl disable --now postgresql

echo "PostgreSQL status:"
sudo systemctl status postgresql --no-pager -l | head -n 8
