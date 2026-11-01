-- ============================================================================
-- XXL-JOB 数据库升级脚本（生产可执行版）
--   起点：xxl-job-admin 3.2.0 / fork 基线 3.3.1-SNAPSHOT（两者库结构完全一致）
--   目标：v3.5.0
--   依据：upstream 3.5.0-release 官方 3.4.0 + 3.5.0 升级脚本，逐表比对 3.5.0 建表脚本
--   环境：MySQL 8.0（5.7 亦可；5.6 需把 RENAME INDEX 改成 DROP + ADD）
--   库名：xxl_job（如不同，只改下一处 USE）
-- ============================================================================
--
-- 【执行前提，逐条确认后再往下跑】
--   1) 已停止旧版 xxl-job-admin 容器（列改名后旧版本会持续报 Unknown column）；
--   2) 已备份：mysqldump --single-transaction --routines xxl_job > xxl_job_bak.sql
--   3) 本脚本非幂等：ADD COLUMN / ADD INDEX / CHANGE / MODIFY 重复执行会报错
--      → 必须先跑 §0 自检，把已经完成的语句注释掉，再执行后面的 DDL；
--   4) 执行顺序：§0 → §1 → §2 → §3 → §4 → §5，不要跳步；
--   5) Token 统一写为 xxl-job-xy，必须与执行器 xxl.job.executor.accessToken 的值一致；
--   6) 预期现象：脚本执行成功、新 admin 起来后，执行器在升级到 xxl-job-core 3.5.0
--      之前注册不上（3.5.0 通讯协议变更），属于预期，不是 SQL 出错。
-- ============================================================================

USE `xxl_job`;

-- ----------------------------------------------------------------------------
-- §0 升级前自检（只读，先跑这一段并记录结果）
-- ----------------------------------------------------------------------------

-- 0.1 一行看清当前库处于什么状态（1 = 已完成，0 = 未做，NULL = 列不存在）
--     结果里哪一项已经是 1，就把 §1~§4 对应的语句注释掉
SELECT
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_group'
       AND column_name = 'name')                                   AS group_name_done,
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_group'
       AND column_name = 'access_token')                           AS access_token_done,
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_info'
       AND column_name = 'name')                                   AS info_name_done,
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_info'
       AND data_type = 'text' AND column_name = 'executor_param')  AS info_param_text_done,
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_log'
       AND data_type = 'text' AND column_name = 'executor_param')  AS log_param_text_done,
  (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_log'
       AND index_name = 'i_job_group')                             AS log_group_idx_done,
  (SELECT COUNT(*) FROM information_schema.statistics
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_log'
       AND index_name = 'i_alarm_status')                          AS log_alarm_idx_done,
  (SELECT data_type FROM information_schema.columns
     WHERE table_schema = DATABASE() AND table_name = 'xxl_job_registry'
       AND column_name = 'id')                                     AS registry_id_type,
  (SELECT COUNT(*) FROM (
       SELECT app_name FROM `xxl_job_group` GROUP BY app_name HAVING COUNT(*) > 1
   ) t)                                                            AS duplicate_appname_cnt;

-- 0.2 执行器分组的 Token 现状（应全为 NULL；若已有值，§1.2 不会覆盖它们）
SELECT id, app_name, name, access_token FROM `xxl_job_group` ORDER BY id;

-- 0.3 日志表规模，用于评估 §4 的 DDL 窗口（行数大时建议单独安排时间）
SELECT table_rows, ROUND(data_length / 1024 / 1024) AS data_mb,
       ROUND(index_length / 1024 / 1024) AS index_mb
FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name = 'xxl_job_log';

-- 0.4 待回填的告警状态（§4.4 需要循环执行到该值为 0）
SELECT COUNT(*) AS pending_backfill
FROM `xxl_job_log`
WHERE `alarm_status` = 0 AND `handle_code` = 200;


-- ============================================================================
-- §1 执行器表 xxl_job_group
--    v3.5.0 起 AccessToken 由全局配置改为执行器维度并落库
-- ============================================================================

-- 1.1 新增 access_token 列（强制：不建列则 3.5.0 的执行器分组查询直接报错）
ALTER TABLE `xxl_job_group`
    ADD COLUMN `access_token` varchar(255) DEFAULT NULL COMMENT '执行器AccessToken'
    AFTER `address_list`;

-- 1.2 补生产 Token（强制）；条件更新：重跑不会覆盖已经单独调整过的值
UPDATE `xxl_job_group`
SET `access_token` = 'xxl-job-xy'
WHERE `access_token` IS NULL OR `access_token` = '';

-- 1.3 字段标准化：title -> name，长度 12 -> 64（强制）
ALTER TABLE `xxl_job_group`
    CHANGE `title` `name` VARCHAR(64) NOT NULL COMMENT '执行器名称';

-- 1.4 AppName 唯一索引（官方脚本包含）
--     若报 Duplicate entry：说明存在重复 app_name，先合并执行器分组再重试
ALTER TABLE `xxl_job_group`
    ADD UNIQUE KEY `i_app_name` (`app_name`) USING BTREE;


-- ============================================================================
-- §2 任务表 xxl_job_info
-- ============================================================================

-- 2.1 字段标准化：job_desc -> name（强制）
ALTER TABLE `xxl_job_info`
    CHANGE `job_desc` `name` VARCHAR(255) NOT NULL COMMENT '任务描述';

-- 2.2 任务参数：varchar(512) -> TEXT，支持最长 2048 字符（建议）
ALTER TABLE `xxl_job_info`
    MODIFY `executor_param` TEXT NULL COMMENT '任务参数';


-- ============================================================================
-- §3 执行器注册表 xxl_job_registry
-- ============================================================================

-- 3.1 主键 int -> bigint（3.4.0 官方项，防大规模集群注册数据溢出；会重建表）
ALTER TABLE `xxl_job_registry`
    MODIFY `id` BIGINT NOT NULL AUTO_INCREMENT;


-- ============================================================================
-- §4 调度日志表 xxl_job_log（大表，建议单独安排窗口）
-- ============================================================================

-- 4.1 一次性完成「参数扩长 + 两个新索引」，避免多次全表重建
--     前提：§0 中 log_param_text_done / log_group_idx_done / log_alarm_idx_done 均为 0
--     若其中某项已完成，请整条降级为逐条执行，并删掉已完成的子句
ALTER TABLE `xxl_job_log`
    MODIFY `executor_param` TEXT NULL COMMENT '任务参数',
    ADD INDEX `i_job_group` (`job_group`),
    ADD INDEX `i_alarm_status` (`alarm_status`);

-- 4.2 删除旧的 (job_id, job_group) 复合索引（可选；job_id 侧由 i_job_id 覆盖）
--     若报 1091 Can't DROP：说明索引已不存在，忽略即可
ALTER TABLE `xxl_job_log` DROP INDEX `I_jobid_jobgroup`;

-- 4.3 索引名统一小写（纯改名，可选；报错直接跳过，不影响 3.5.0 运行）
ALTER TABLE `xxl_job_log` RENAME INDEX `I_job_id` TO `i_job_id`;
ALTER TABLE `xxl_job_log` RENAME INDEX `I_trigger_time` TO `i_trigger_time`;
ALTER TABLE `xxl_job_log` RENAME INDEX `I_handle_code` TO `i_handle_code`;

-- 4.4 历史数据回填（建议但重要）
--     3.5.0 的 alarm_status 语义：0-默认、-1=锁定中、1-无需告警、2-告警成功、3-告警失败
--     历史「执行成功」的日志仍为 0，升级后会被告警巡检反复扫描，回填为 1。
--     单次 1W 条避免长事务：请重复执行本语句，直到「影响行数 = 0」。
--     shell 循环示例（在数据库服务器上执行，账号密码按实际替换）：
--       while :; do
--         n=$(mysql -N -uroot -p"$MYSQL_PWD" xxl_job -e \
--              "UPDATE xxl_job_log SET alarm_status=1 WHERE alarm_status=0 AND handle_code=200 LIMIT 10000; SELECT ROW_COUNT();")
--         echo "updated=$n"; [ "$n" = "0" ] && break
--       done
UPDATE `xxl_job_log`
SET `alarm_status` = 1
WHERE `alarm_status` = 0
  AND `handle_code` = 200
LIMIT 10000;

-- 4.5（可选）清理历史遗留的锁定态；只有确认无需再告警时才执行
-- UPDATE `xxl_job_log` SET `alarm_status` = 1
-- WHERE `alarm_status` = -1 AND `handle_time` < DATE_SUB(NOW(), INTERVAL 1 DAY);


-- ============================================================================
-- §5 升级后校验（全部通过再做下一步）
-- ============================================================================

-- 5.1 表结构：应包含 name / access_token / i_app_name；不再有 title / job_desc；registry.id 为 bigint
SHOW CREATE TABLE `xxl_job_group`;
SHOW CREATE TABLE `xxl_job_info`;
SHOW CREATE TABLE `xxl_job_registry`;
SHOW CREATE TABLE `xxl_job_log`;

-- 5.2 索引：应包含 i_job_group、i_alarm_status、i_job_id、i_trigger_time、i_handle_code
SHOW INDEX FROM `xxl_job_log`;

-- 5.3 数据：token 必须全部为 xxl-job-xy，且无空值
SELECT id, app_name, name, access_token FROM `xxl_job_group` ORDER BY id;

-- 5.4 回填彻底完成：结果为 0
SELECT COUNT(*) AS pending_backfill
FROM `xxl_job_log`
WHERE `alarm_status` = 0 AND `handle_code` = 200;
