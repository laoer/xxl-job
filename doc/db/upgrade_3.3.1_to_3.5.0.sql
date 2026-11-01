-- =====================================================================
-- XXL-JOB 数据库升级脚本
-- 源版本：3.3.1-SNAPSHOT（fork 基线 166c2860，与 doc/db/tables_xxl_job.sql 旧版一致）
-- 目标版本：v3.5.0（upstream 3bebfc16）
-- 数据库：MySQL 8.0（MySQL 5.7 亦可，RENAME INDEX 需 >= 5.7；5.6 请改用 DROP+ADD）
--
-- 执行约定：
--   1、执行前务必备份：mysqldump --single-transaction xxl_job > xxl_job_bak.sql
--   2、建议在维护窗口执行：升级后 xxl_job_group.title / xxl_job_info.job_desc
--      被重命名，旧版本调度中心的 SQL 会直接报 Unknown column，不可与旧版本并行运行；
--   3、大表（xxl_job_log）变更涉及表锁 / 索引重建，请评估耗时；
--   4、脚本按章顺序执行，不要跳步。
-- =====================================================================

-- 库名按实际环境调整
USE `xxl_job`;

-- ---------------------------------------------------------------------
-- 0、前置检查（只读，确认后再执行后面的 DDL）
-- ---------------------------------------------------------------------
-- 0.1 执行器 AppName 是否存在重复：有结果必须先清理，否则第 1.3 步唯一索引会失败
SELECT `app_name`, COUNT(*) AS cnt
FROM `xxl_job_group`
GROUP BY `app_name`
HAVING cnt > 1;

-- 0.2 当前索引清单（用于对照第 4 步）
SHOW INDEX FROM `xxl_job_log`;

-- 0.3 历史日志量（决定第 4.4 步回填耗时）
SELECT COUNT(*) AS total,
       SUM(CASE WHEN `alarm_status` = 0 AND `handle_code` = 200 THEN 1 ELSE 0 END) AS need_backfill
FROM `xxl_job_log`;


-- =====================================================================
-- 1、执行器表 xxl_job_group
--    v3.5.0：AccessToken 从“全局配置”下沉为“执行器维度”，并落库
-- =====================================================================
-- 1.1 新增 access_token 列
ALTER TABLE `xxl_job_group`
    ADD COLUMN `access_token` varchar(255) DEFAULT NULL COMMENT '执行器AccessToken' AFTER `address_list`;

-- 1.2 为存量执行器补 Token（兜底值 default_token，与官方示例一致）
--     若希望每个执行器使用不同 Token，请在第 1.4 步之后、启动新版本前逐个设置，
--     并同步修改对应执行器的 xxl.job.executor.accessToken。
UPDATE `xxl_job_group`
SET `access_token` = 'default_token'
WHERE `access_token` IS NULL OR `access_token` = '';

-- 1.3 AppName 唯一索引（v3.5.0 起 UI 不允许重复 AppName）
ALTER TABLE `xxl_job_group`
    ADD UNIQUE KEY `i_app_name` (`app_name`) USING BTREE;

-- 1.4 字段标准化：title -> name，长度 12 -> 64
ALTER TABLE `xxl_job_group`
    CHANGE `title` `name` VARCHAR(64) NOT NULL COMMENT '执行器名称';

-- 1.5（可选）按执行器设置独立 Token：<新Token值> / <目标AppName> 需替换
-- UPDATE `xxl_job_group` SET `access_token` = '<新Token值>' WHERE `app_name` = '<目标AppName>';


-- =====================================================================
-- 2、任务表 xxl_job_info
-- =====================================================================
-- 2.1 字段标准化：job_desc -> name
ALTER TABLE `xxl_job_info`
    CHANGE `job_desc` `name` VARCHAR(255) NOT NULL COMMENT '任务描述';

-- 2.2 任务参数长度：varchar(512) -> text（最长支持 2048 字符）
ALTER TABLE `xxl_job_info`
    MODIFY `executor_param` TEXT NULL COMMENT '任务参数';


-- =====================================================================
-- 3、执行器注册表 xxl_job_registry
-- =====================================================================
-- 3.1 主键 int -> bigint，避免大规模执行器集群注册数据溢出（会重建表，注意耗时）
ALTER TABLE `xxl_job_registry`
    MODIFY `id` BIGINT NOT NULL AUTO_INCREMENT;


-- =====================================================================
-- 4、调度日志表 xxl_job_log
-- =====================================================================
-- 4.1 任务参数长度：varchar(512) -> text
ALTER TABLE `xxl_job_log`
    MODIFY `executor_param` TEXT NULL COMMENT '任务参数';

-- 4.2 索引调整：按 job_group 单独建索引，替换旧的 (job_id, job_group) 复合索引；
--     统一索引命名（大写 I_ -> 小写 i_），便于与 3.5.0 建表脚本保持一致。
ALTER TABLE `xxl_job_log` ADD INDEX `i_job_group` (`job_group`);
ALTER TABLE `xxl_job_log` DROP INDEX `I_jobid_jobgroup`;

-- 以下三条仅用于统一索引命名（功能等价，可跳过不改名）；
-- MySQL < 5.7 不支持 RENAME INDEX，可改为 DROP INDEX 旧名 + ADD INDEX 新名；
-- 如遇大小写相关报错，直接跳过即可，不影响 v3.5.0 运行。
ALTER TABLE `xxl_job_log` RENAME INDEX `I_job_id` TO `i_job_id`;
ALTER TABLE `xxl_job_log` RENAME INDEX `I_trigger_time` TO `i_trigger_time`;
ALTER TABLE `xxl_job_log` RENAME INDEX `I_handle_code` TO `i_handle_code`;

-- 4.3 告警巡检索引（v3.5.0 失败告警改为“先锁定、再告警”，按 alarm_status 扫描）
ALTER TABLE `xxl_job_log`
    ADD INDEX `i_alarm_status` (`alarm_status`);

-- 4.4 历史数据回填（重要）：
--     v3.5.0 中 alarm_status 语义：0-默认、-1=锁定中、1-无需告警、2-告警成功、3-告警失败
--     历史“执行成功”的日志仍为 0，升级后会被告警巡检反复扫描，故回填为 1。
--     单次 1W 条，避免大表长事务；请重复执行直到“影响行数 = 0”。
UPDATE `xxl_job_log`
SET `alarm_status` = 1
WHERE `alarm_status` = 0
  AND `handle_code` = 200
LIMIT 10000;

-- 4.5（可选）若历史上存在告警过程中断导致长期停留在 -1 的记录（锁定态不会再次被扫描），
--     确认无需再告警后可重置为 1（不建议重置为 0）：
-- UPDATE `xxl_job_log` SET `alarm_status` = 1 WHERE `alarm_status` = -1 AND `handle_time` < DATE_SUB(NOW(), INTERVAL 1 DAY);


-- =====================================================================
-- 5、升级后核对：列与索引应和 doc/db/tables_xxl_job.sql（v3.5.0）一致
-- =====================================================================
SHOW CREATE TABLE `xxl_job_group`;
SHOW CREATE TABLE `xxl_job_info`;
SHOW CREATE TABLE `xxl_job_registry`;
SHOW CREATE TABLE `xxl_job_log`;
