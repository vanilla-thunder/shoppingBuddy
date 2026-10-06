"""initial schema

Revision ID: 0b83f7568a4b
Revises: 
Create Date: 2026-10-06 03:27:36.048121
"""

from alembic import op
import sqlalchemy as sa

revision = '0b83f7568a4b'
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table('products',
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('name', sa.String(length=300), nullable=False),
    sa.Column('brand', sa.String(length=200), nullable=True),
    sa.Column('rating', sa.Integer(), nullable=True),
    sa.Column('notes', sa.Text(), nullable=True),
    sa.Column('category', sa.String(length=100), server_default='local', nullable=False),
    sa.Column('created_at', sa.DateTime(), nullable=False),
    sa.Column('updated_at', sa.DateTime(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('merged_into', sa.String(length=36), nullable=True),
    sa.Column('server_seq', sa.Integer(), nullable=False),
    sa.CheckConstraint('rating IS NULL OR rating BETWEEN 1 AND 5', name=op.f('ck_products_rating_range')),
    sa.ForeignKeyConstraint(['merged_into'], ['products.id'], name=op.f('fk_products_merged_into_products')),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_products'))
    )
    with op.batch_alter_table('products', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_products_category'), ['category'], unique=False)
        batch_op.create_index(batch_op.f('ix_products_server_seq'), ['server_seq'], unique=False)

    sync_state = op.create_table('sync_state',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('last_seq', sa.Integer(), nullable=False),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_sync_state'))
    )
    # The single counter row every server_seq is drawn from (see app.services.next_seq).
    op.bulk_insert(sync_state, [{'id': 1, 'last_seq': 0}])
    op.create_table('identifiers',
    sa.Column('id', sa.String(length=36), nullable=False),
    sa.Column('product_id', sa.String(length=36), nullable=False),
    sa.Column('type', sa.String(length=20), nullable=False),
    sa.Column('value', sa.String(length=64), nullable=False),
    sa.Column('store', sa.String(length=100), nullable=False),
    sa.Column('created_at', sa.DateTime(), nullable=False),
    sa.Column('updated_at', sa.DateTime(), nullable=False),
    sa.Column('deleted', sa.Boolean(), nullable=False),
    sa.Column('server_seq', sa.Integer(), nullable=False),
    sa.ForeignKeyConstraint(['product_id'], ['products.id'], name=op.f('fk_identifiers_product_id_products')),
    sa.PrimaryKeyConstraint('id', name=op.f('pk_identifiers'))
    )
    with op.batch_alter_table('identifiers', schema=None) as batch_op:
        batch_op.create_index(batch_op.f('ix_identifiers_product_id'), ['product_id'], unique=False)
        batch_op.create_index(batch_op.f('ix_identifiers_server_seq'), ['server_seq'], unique=False)
        batch_op.create_index('uq_identifier_live', ['type', 'value', 'store'], unique=True, sqlite_where=sa.text('NOT deleted'), postgresql_where=sa.text('NOT deleted'))



def downgrade() -> None:
    with op.batch_alter_table('identifiers', schema=None) as batch_op:
        batch_op.drop_index('uq_identifier_live', sqlite_where=sa.text('NOT deleted'), postgresql_where=sa.text('NOT deleted'))
        batch_op.drop_index(batch_op.f('ix_identifiers_server_seq'))
        batch_op.drop_index(batch_op.f('ix_identifiers_product_id'))

    op.drop_table('identifiers')
    op.drop_table('sync_state')
    with op.batch_alter_table('products', schema=None) as batch_op:
        batch_op.drop_index(batch_op.f('ix_products_server_seq'))
        batch_op.drop_index(batch_op.f('ix_products_category'))

    op.drop_table('products')
