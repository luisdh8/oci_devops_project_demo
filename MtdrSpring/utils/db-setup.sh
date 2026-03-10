#!/bin/bash
# Copyright (c) 2022 Oracle and/or its affiliates.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

# Fail on error
set -e


# Create Object Store Bucket (Should be replaced by terraform one day)
while ! state_done OBJECT_STORE_BUCKET; do
  echo "Checking object storage bucket"
#  oci os bucket create --compartment-id "$(state_get COMPARTMENT_OCID)" --name "$(state_get RUN_NAME)"
  if oci os bucket get --name "$(state_get RUN_NAME)-$(state_get MTDR_KEY)"; then
    state_set_done OBJECT_STORE_BUCKET
    echo "finished checking object storage bucket"
  fi
done


# Wait for Order DB OCID
while ! state_done MTDR_DB_OCID; do
  echo "`date`: Waiting for MTDR_DB_OCID"
  sleep 2
done


# Get Wallet
while ! state_done WALLET_GET; do
  echo "creating wallet"
  cd $MTDRWORKSHOP_LOCATION
  mkdir wallet
  cd wallet
  oci db autonomous-database generate-wallet --autonomous-database-id "$(state_get MTDR_DB_OCID)" --file 'wallet.zip' --password 'Welcome1' --generate-type 'ALL'
  unzip wallet.zip
  cd $MTDRWORKSHOP_LOCATION
  state_set_done WALLET_GET
  echo "finished creating wallet"
done


# Get DB Connection Wallet and to Object Store
while ! state_done CWALLET_SSO_OBJECT; do
  echo "grabbing wallet"
  cd $MTDRWORKSHOP_LOCATION/wallet
  oci os object put --bucket-name "$(state_get RUN_NAME)-$(state_get MTDR_KEY)" --name "cwallet.sso" --file 'cwallet.sso'
  cd $MTDRWORKSHOP_LOCATION
  state_set_done CWALLET_SSO_OBJECT
  echo "done grabbing wallet"
done


# Create Authenticated Link to Wallet
while ! state_done CWALLET_SSO_AUTH_URL; do
  echo "creating authenticated link to wallet"
  ACCESS_URI=`oci os preauth-request create --object-name 'cwallet.sso' --access-type 'ObjectRead' --bucket-name "$(state_get RUN_NAME)-$(state_get MTDR_KEY)" --name 'mtdrworkshop' --time-expires $(date '+%Y-%m-%d' --date '+7 days') --query 'data."access-uri"' --raw-output`
  state_set CWALLET_SSO_AUTH_URL "https://objectstorage.$(state_get REGION).oraclecloud.com${ACCESS_URI}"
  echo "done creating authenticated link to wallet"
done


# Give DB_PASSWORD priority
while ! state_done DB_PASSWORD; do
  echo "Waiting for DB_PASSWORD"
  sleep 5
done


# Create Inventory ATP Bindings
while ! state_done DB_WALLET_SECRET; do
  echo "creating Inventory ATP Bindings"
  cd $MTDRWORKSHOP_LOCATION/wallet
  cat - >sqlnet.ora <<!
WALLET_LOCATION = (SOURCE = (METHOD = file) (METHOD_DATA = (DIRECTORY="/mtdrworkshop/creds")))
SSL_SERVER_DN_MATCH=yes
!
  if kubectl create -f - -n mtdrworkshop; then
    state_set_done DB_WALLET_SECRET
  else
    echo "Error: Failure to create db-wallet-secret.  Retrying..."
    sleep 5
  fi <<!
apiVersion: v1
data:
  README: $(base64 -w0 README)
  cwallet.sso: $(base64 -w0 cwallet.sso)
  ewallet.p12: $(base64 -w0 ewallet.p12)
  keystore.jks: $(base64 -w0 keystore.jks)
  ojdbc.properties: $(base64 -w0 ojdbc.properties)
  sqlnet.ora: $(base64 -w0 sqlnet.ora)
  tnsnames.ora: $(base64 -w0 tnsnames.ora)
  truststore.jks: $(base64 -w0 truststore.jks)
kind: Secret
metadata:
  name: db-wallet-secret
!
  cd $MTDRWORKSHOP_LOCATION
done


# DB Connection Setup
export TNS_ADMIN=$MTDRWORKSHOP_LOCATION/wallet
cat - >$TNS_ADMIN/sqlnet.ora <<!
WALLET_LOCATION = (SOURCE = (METHOD = file) (METHOD_DATA = (DIRECTORY="$TNS_ADMIN")))
SSL_SERVER_DN_MATCH=yes
!
MTDR_DB_SVC="$(state_get MTDR_DB_NAME)_tp"
TODO_USER=TODOUSER
ORDER_LINK=ORDERTOINVENTORYLINK
ORDER_QUEUE=ORDERQUEUE


# Get DB Password
while true; do
  if DB_PASSWORD=`kubectl get secret dbuser -n mtdrworkshop --template={{.data.dbpassword}} | base64 --decode`; then
    if ! test -z "$DB_PASSWORD"; then
      break
    fi
  fi
  echo "Error: Failed to get DB password.  Retrying..."
  sleep 5
done


# Wait for DB Password to be set in Order DB
while ! state_done MTDR_DB_PASSWORD_SET; do
  echo "`date`: Waiting for MTDR_DB_PASSWORD_SET"
  sleep 2
done


# Order DB User, Objects
while ! state_done TODO_USER; do
  echo "connecting to mtdr database"
  U=$TODO_USER
  SVC=$MTDR_DB_SVC
  sqlplus /nolog <<!
WHENEVER SQLERROR EXIT 1
connect admin/"$DB_PASSWORD"@$SVC
CREATE USER $U IDENTIFIED BY "$DB_PASSWORD" DEFAULT TABLESPACE data QUOTA UNLIMITED ON data;
GRANT CREATE SESSION, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO $U;
GRANT CREATE TABLE, CREATE TRIGGER, CREATE TYPE, CREATE MATERIALIZED VIEW TO $U;
GRANT CONNECT, RESOURCE, pdb_dba, SODA_APP to $U;
ALTER SESSION SET CURRENT_SCHEMA = $U;

-- =============================================================================
-- 0. LIMPIEZA  (drop existing tables if any)
-- =============================================================================
BEGIN
    FOR t IN (
        SELECT table_name FROM user_tables
        WHERE  table_name IN (
            'USUARIO_A_PROYECTO','USUARIO_A_TAREA','USUARIO_A_EQUIPO',
            'COMENTARIO','TAREA','PROYECTO','EQUIPO','USUARIO',
            'CAT_PRIORIDAD','CAT_ESTADO_TAREA',
            'CAT_ESTADO_USUARIO','CAT_ROL'
        )
    ) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

-- =============================================================================
-- 1. TABLAS DE CATALOGO (Lookup Tables)
-- =============================================================================

CREATE TABLE CAT_ROL (
    rol_id      NUMBER(3)    NOT NULL,
    nombre      VARCHAR2(50) NOT NULL,
    descripcion VARCHAR2(500),
    CONSTRAINT PK_CAT_ROL       PRIMARY KEY (rol_id),
    CONSTRAINT UQ_CAT_ROL_NOMB  UNIQUE      (nombre)
);

CREATE TABLE CAT_ESTADO_USUARIO (
    estado_id   NUMBER(3)    NOT NULL,
    nombre      VARCHAR2(50) NOT NULL,
    descripcion VARCHAR2(500),
    CONSTRAINT PK_CAT_EST_USR      PRIMARY KEY (estado_id),
    CONSTRAINT UQ_CAT_EST_USR_NOMB UNIQUE      (nombre)
);

CREATE TABLE CAT_ESTADO_TAREA (
    estado_id   NUMBER(3)    NOT NULL,
    nombre      VARCHAR2(50) NOT NULL,
    descripcion VARCHAR2(500),
    es_activo   NUMBER(1)    NOT NULL,
    CONSTRAINT PK_CAT_EST_TAR        PRIMARY KEY (estado_id),
    CONSTRAINT UQ_CAT_EST_TAR_NOMB   UNIQUE      (nombre),
    CONSTRAINT CK_CAT_EST_TAR_ACTIVO CHECK       (es_activo IN (0, 1))
);

CREATE TABLE CAT_PRIORIDAD (
    prioridad_id NUMBER(3)    NOT NULL,
    nombre       VARCHAR2(50) NOT NULL,
    descripcion  VARCHAR2(500),
    orden        NUMBER(3)    NOT NULL,
    CONSTRAINT PK_CAT_PRIO          PRIMARY KEY (prioridad_id),
    CONSTRAINT UQ_CAT_PRIO_NOMB     UNIQUE      (nombre),
    CONSTRAINT UQ_CAT_PRIO_ORDEN    UNIQUE      (orden),
    CONSTRAINT CK_CAT_PRIO_ORDEN    CHECK       (orden > 0)
);

-- =============================================================================
-- 2. ENTIDADES PRINCIPALES
-- =============================================================================

CREATE TABLE USUARIO (
    user_id       RAW(16)       DEFAULT SYS_GUID() NOT NULL,
    primer_nombre VARCHAR2(500) NOT NULL,
    apellido      VARCHAR2(500) NOT NULL,
    telefono      VARCHAR2(50),
    email         VARCHAR2(320) NOT NULL,
    telegram_id   VARCHAR2(50)  NOT NULL,
    rol_id        NUMBER(3)     NOT NULL,
    estado_id     NUMBER(3)     NOT NULL,
    manager_id    RAW(16),
    CONSTRAINT PK_USUARIO          PRIMARY KEY (user_id),
    CONSTRAINT UQ_USUARIO_EMAIL    UNIQUE      (email),
    CONSTRAINT UQ_USUARIO_TELEGRAM UNIQUE      (telegram_id),
    CONSTRAINT FK_USUARIO_ROL      FOREIGN KEY (rol_id)
                                   REFERENCES  CAT_ROL (rol_id),
    CONSTRAINT FK_USUARIO_ESTADO   FOREIGN KEY (estado_id)
                                   REFERENCES  CAT_ESTADO_USUARIO (estado_id),
    CONSTRAINT FK_USUARIO_MANAGER  FOREIGN KEY (manager_id)
                                   REFERENCES  USUARIO (user_id)
);

CREATE TABLE EQUIPO (
    team_id     RAW(16)       DEFAULT SYS_GUID() NOT NULL,
    nombre      VARCHAR2(500) NOT NULL,
    descripcion VARCHAR2(500),
    user_id     RAW(16)       NOT NULL,
    CONSTRAINT PK_EQUIPO        PRIMARY KEY (team_id),
    CONSTRAINT FK_EQUIPO_OWNER  FOREIGN KEY (user_id)
                                REFERENCES  USUARIO (user_id)
);

CREATE TABLE PROYECTO (
    project_id  RAW(16)       DEFAULT SYS_GUID() NOT NULL,
    nombre      VARCHAR2(500) NOT NULL,
    descripcion VARCHAR2(500),
    fecha_inicio TIMESTAMP,
    fecha_fin    TIMESTAMP,
    progreso     FLOAT         DEFAULT 0 NOT NULL,
    team_id      RAW(16)       NOT NULL,
    CONSTRAINT PK_PROYECTO          PRIMARY KEY (project_id),
    CONSTRAINT FK_PROYECTO_EQUIPO   FOREIGN KEY (team_id)
                                    REFERENCES  EQUIPO (team_id),
    CONSTRAINT CK_PROYECTO_PROGRESO CHECK       (progreso BETWEEN 0 AND 100)
);

CREATE TABLE TAREA (
    task_id          RAW(16)      DEFAULT SYS_GUID() NOT NULL,
    titulo           VARCHAR2(120) NOT NULL,
    descripcion      VARCHAR2(500),
    fecha_creacion   TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
    fecha_limite     TIMESTAMP    NOT NULL,
    tiempo_estimado  FLOAT,
    tiempo_real      FLOAT,
    estado_id        NUMBER(3)    NOT NULL,
    prioridad_id     NUMBER(3)    NOT NULL,
    proyect_id       RAW(16)      NOT NULL,
    CONSTRAINT PK_TAREA            PRIMARY KEY (task_id),
    CONSTRAINT FK_TAREA_ESTADO     FOREIGN KEY (estado_id)
                                   REFERENCES  CAT_ESTADO_TAREA (estado_id),
    CONSTRAINT FK_TAREA_PRIORIDAD  FOREIGN KEY (prioridad_id)
                                   REFERENCES  CAT_PRIORIDAD (prioridad_id),
    CONSTRAINT FK_TAREA_PROYECTO   FOREIGN KEY (proyect_id)
                                   REFERENCES  PROYECTO (project_id),
    CONSTRAINT CK_TAREA_FECHA      CHECK       (fecha_limite > fecha_creacion)
);

CREATE TABLE COMENTARIO (
    comment_id RAW(16)  DEFAULT SYS_GUID() NOT NULL,
    fecha      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
    contenido  CLOB      NOT NULL,
    task_id    RAW(16)   NOT NULL,
    user_id    RAW(16)   NOT NULL,
    CONSTRAINT PK_COMENTARIO        PRIMARY KEY (comment_id),
    CONSTRAINT FK_COMENT_TAREA      FOREIGN KEY (task_id)
                                    REFERENCES  TAREA (task_id)
                                    ON DELETE CASCADE,
    CONSTRAINT FK_COMENT_USUARIO    FOREIGN KEY (user_id)
                                    REFERENCES  USUARIO (user_id)
);

-- =============================================================================
-- 3. TABLAS DE UNION (Many-to-Many)
-- =============================================================================

CREATE TABLE USUARIO_A_EQUIPO (
    user_id  RAW(16) NOT NULL,
    team_id  RAW(16) NOT NULL,
    CONSTRAINT PK_USR_EQP       PRIMARY KEY (user_id, team_id),
    CONSTRAINT FK_USR_EQP_USR   FOREIGN KEY (user_id)
                                REFERENCES  USUARIO (user_id),
    CONSTRAINT FK_USR_EQP_EQP   FOREIGN KEY (team_id)
                                REFERENCES  EQUIPO (team_id)
);

CREATE TABLE USUARIO_A_TAREA (
    user_id  RAW(16) NOT NULL,
    task_id  RAW(16) NOT NULL,
    CONSTRAINT PK_USR_TAR       PRIMARY KEY (user_id, task_id),
    CONSTRAINT FK_USR_TAR_USR   FOREIGN KEY (user_id)
                                REFERENCES  USUARIO (user_id),
    CONSTRAINT FK_USR_TAR_TAR   FOREIGN KEY (task_id)
                                REFERENCES  TAREA (task_id)
                                ON DELETE CASCADE
);

CREATE TABLE USUARIO_A_PROYECTO (
    user_id    RAW(16) NOT NULL,
    project_id RAW(16) NOT NULL,
    CONSTRAINT PK_USR_PRY       PRIMARY KEY (user_id, project_id),
    CONSTRAINT FK_USR_PRY_USR   FOREIGN KEY (user_id)
                                REFERENCES  USUARIO (user_id),
    CONSTRAINT FK_USR_PRY_PRY   FOREIGN KEY (project_id)
                                REFERENCES  PROYECTO (project_id)
);

-- =============================================================================
-- 4. INDICES DE SOPORTE
-- =============================================================================

CREATE INDEX IDX_USUARIO_ROL_ID     ON USUARIO    (rol_id);
CREATE INDEX IDX_USUARIO_ESTADO_ID  ON USUARIO    (estado_id);
CREATE INDEX IDX_USUARIO_MANAGER    ON USUARIO    (manager_id);
CREATE INDEX IDX_PROYECTO_TEAM      ON PROYECTO   (team_id);
CREATE INDEX IDX_TAREA_ESTADO       ON TAREA      (estado_id);
CREATE INDEX IDX_TAREA_PRIORIDAD    ON TAREA      (prioridad_id);
CREATE INDEX IDX_TAREA_PROYECTO     ON TAREA      (proyect_id);
CREATE INDEX IDX_TAREA_FECHA_LIM    ON TAREA      (fecha_limite);
CREATE INDEX IDX_COMENT_TASK        ON COMENTARIO (task_id);
CREATE INDEX IDX_COMENT_USER        ON COMENTARIO (user_id);
CREATE INDEX IDX_UAT_TASK           ON USUARIO_A_TAREA    (task_id);
CREATE INDEX IDX_UAP_PROJECT        ON USUARIO_A_PROYECTO (project_id);
CREATE INDEX IDX_UAE_TEAM           ON USUARIO_A_EQUIPO   (team_id);

-- =============================================================================
-- 5. TRIGGER — Recalculo automatico de progreso
-- =============================================================================

CREATE OR REPLACE TRIGGER TRG_RECALC_PROGRESO
AFTER INSERT OR UPDATE OF estado_id OR DELETE
ON TAREA
FOR EACH ROW
DECLARE
    v_project_id  TAREA.proyect_id%TYPE;
    v_total       NUMBER;
    v_completadas NUMBER;
    v_progreso    FLOAT;
BEGIN
    IF DELETING THEN
        v_project_id := :OLD.proyect_id;
    ELSE
        v_project_id := :NEW.proyect_id;
    END IF;

    SELECT COUNT(*)
      INTO v_total
      FROM TAREA t
     WHERE t.proyect_id = v_project_id
       AND t.estado_id  <> 4;

    SELECT COUNT(*)
      INTO v_completadas
      FROM TAREA t
     WHERE t.proyect_id = v_project_id
       AND t.estado_id  = 3;

    IF v_total = 0 THEN
        v_progreso := 0;
    ELSE
        v_progreso := ROUND((v_completadas / v_total) * 100, 2);
    END IF;

    UPDATE PROYECTO
       SET progreso = v_progreso
     WHERE project_id = v_project_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'TRG_RECALC_PROGRESO: Error al recalcular progreso del proyecto '
            || RAWTOHEX(v_project_id) || ' - ' || SQLERRM
        );
END TRG_RECALC_PROGRESO;
/

-- =============================================================================
-- 6. DATOS SEMILLA (Lookup Tables)
-- =============================================================================

INSERT INTO CAT_ROL (rol_id, nombre, descripcion) VALUES
    (1, 'Manager',   'Puede crear, editar, eliminar y asignar tareas.');
INSERT INTO CAT_ROL (rol_id, nombre, descripcion) VALUES
    (2, 'Developer', 'Puede consultar sus tareas asignadas.');

INSERT INTO CAT_ESTADO_USUARIO (estado_id, nombre, descripcion) VALUES
    (1, 'Activo',   'El usuario puede acceder al sistema.');
INSERT INTO CAT_ESTADO_USUARIO (estado_id, nombre, descripcion) VALUES
    (2, 'Inactivo', 'El usuario ha sido desactivado y no puede acceder.');

INSERT INTO CAT_ESTADO_TAREA (estado_id, nombre, descripcion, es_activo) VALUES
    (1, 'Pendiente',   'Tarea creada, aun no iniciada.',         1);
INSERT INTO CAT_ESTADO_TAREA (estado_id, nombre, descripcion, es_activo) VALUES
    (2, 'En_Proceso',  'Tarea actualmente en desarrollo.',        1);
INSERT INTO CAT_ESTADO_TAREA (estado_id, nombre, descripcion, es_activo) VALUES
    (3, 'Completada',  'Tarea finalizada exitosamente.',          0);
INSERT INTO CAT_ESTADO_TAREA (estado_id, nombre, descripcion, es_activo) VALUES
    (4, 'Cancelada',   'Tarea cancelada. No cuenta en progreso.', 0);

INSERT INTO CAT_PRIORIDAD (prioridad_id, nombre, descripcion, orden) VALUES
    (1, 'Alta',  'Requiere atencion inmediata.',  1);
INSERT INTO CAT_PRIORIDAD (prioridad_id, nombre, descripcion, orden) VALUES
    (2, 'Media', 'Atencion en tiempo normal.',    2);
INSERT INTO CAT_PRIORIDAD (prioridad_id, nombre, descripcion, orden) VALUES
    (3, 'Baja',  'Puede resolverse cuando haya disponibilidad.', 3);

COMMIT;
!
  state_set_done TODO_USER
  echo "finished connecting to database and creating schema"
done
# DB Setup Done
state_set_done DB_SETUP