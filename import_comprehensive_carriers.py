#!/usr/bin/env python3
import sqlite3
import csv
import sys
from datetime import datetime

def create_comprehensive_carriers_db():
    """Import matched carriers CSV into a comprehensive database table"""

    print("🚀 Starting comprehensive carriers database import...")

    # Database path
    db_path = '/home/corp06/fcsma_full_leads.db'
    csv_path = '/home/corp06/matched_carriers_20251009_183433_updated.csv'

    try:
        # Connect to database
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()

        # Create comprehensive carriers table
        print("📋 Creating comprehensive carriers table...")
        cursor.execute('''DROP TABLE IF EXISTS comprehensive_carriers''')

        cursor.execute('''
            CREATE TABLE comprehensive_carriers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mc_number TEXT,
                dot_number TEXT,
                insurance_record TEXT,
                fmcsa_dot_number TEXT,
                legal_name TEXT,
                dba_name TEXT,
                street TEXT,
                city TEXT,
                state TEXT,
                zip_code TEXT,
                phone TEXT,
                email_address TEXT,
                entity_type TEXT,
                operating_status TEXT,
                carrier_operation TEXT,
                drivers TEXT,
                power_units TEXT,
                insurance_company TEXT,
                insurance_expiration TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')

        # Create indexes for performance
        cursor.execute('CREATE INDEX idx_comp_dot_number ON comprehensive_carriers(dot_number)')
        cursor.execute('CREATE INDEX idx_comp_state ON comprehensive_carriers(state)')
        cursor.execute('CREATE INDEX idx_comp_insurance_company ON comprehensive_carriers(insurance_company)')
        cursor.execute('CREATE INDEX idx_comp_insurance_expiration ON comprehensive_carriers(insurance_expiration)')
        cursor.execute('CREATE INDEX idx_comp_power_units ON comprehensive_carriers(power_units)')

        print("✅ Table created successfully")

        # Import CSV data
        print("📊 Importing CSV data...")

        with open(csv_path, 'r', encoding='utf-8') as csvfile:
            reader = csv.DictReader(csvfile)

            # Prepare insert statement
            insert_sql = '''
                INSERT INTO comprehensive_carriers
                (mc_number, dot_number, insurance_record, fmcsa_dot_number, legal_name, dba_name,
                 street, city, state, zip_code, phone, email_address, entity_type, operating_status,
                 carrier_operation, drivers, power_units, insurance_company, insurance_expiration)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            '''

            batch = []
            count = 0

            for row in reader:
                # Clean and prepare data
                data = (
                    row.get('mc_number', ''),
                    row.get('dot_number', ''),
                    row.get('insurance_record', ''),
                    row.get('fmcsa_dot_number', ''),
                    row.get('legal_name', ''),
                    row.get('dba_name', ''),
                    row.get('street', ''),
                    row.get('city', ''),
                    row.get('state', ''),
                    row.get('zip_code', ''),
                    row.get('phone', ''),
                    row.get('email_address', ''),
                    row.get('entity_type', ''),
                    row.get('operating_status', ''),
                    row.get('carrier_operation', ''),
                    row.get('drivers', ''),
                    row.get('power_units', ''),
                    row.get('insurance_company', ''),
                    row.get('insurance_expiration', '')
                )

                batch.append(data)
                count += 1

                # Insert in batches of 1000
                if len(batch) >= 1000:
                    cursor.executemany(insert_sql, batch)
                    batch = []
                    if count % 10000 == 0:
                        print(f"   📈 Imported {count:,} records...")

            # Insert remaining records
            if batch:
                cursor.executemany(insert_sql, batch)

            print(f"✅ Successfully imported {count:,} carrier records")

        # Commit changes
        conn.commit()

        # Get final statistics
        cursor.execute("SELECT COUNT(*) FROM comprehensive_carriers")
        total_records = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(DISTINCT state) FROM comprehensive_carriers")
        total_states = cursor.fetchone()[0]

        cursor.execute("SELECT COUNT(DISTINCT insurance_company) FROM comprehensive_carriers WHERE insurance_company != ''")
        total_insurers = cursor.fetchone()[0]

        print(f"\n🎯 Database Import Complete!")
        print(f"   📊 Total carriers: {total_records:,}")
        print(f"   🏛️  States covered: {total_states}")
        print(f"   🏢 Insurance companies: {total_insurers:,}")

        conn.close()

        return {
            'success': True,
            'total_records': total_records,
            'total_states': total_states,
            'total_insurers': total_insurers
        }

    except Exception as e:
        print(f"❌ Error importing data: {e}")
        if 'conn' in locals():
            conn.close()
        return {'success': False, 'error': str(e)}

if __name__ == "__main__":
    result = create_comprehensive_carriers_db()
    print(f"\n🔚 Final result: {result}")