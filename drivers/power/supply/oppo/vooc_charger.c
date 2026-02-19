// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (C) 2008-2012, OPPO Mobile Comm Corp., Ltd
 * Copyright (c) 2025-2026 Ricky Cheung <rcheung844@gmail.com>
 */

#define DEBUG

#include <asm-generic/errno.h>
#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/power_supply.h>
#include <linux/swab.h>

#include <linux/power/oppo_gauge.h>
#include <linux/power/oppo_vooc.h>

static char *fw_name = "vooc_fw.bin";
module_param(fw_name, charp, S_IRUGO | S_IWUSR);
MODULE_PARM_DESC(fw_name, "OPPO VOOC microcontroller (MCU) firmware name.");

void vooc_set_fast_charge_enabled(struct oppo_vooc_device *vooc, bool enabled)
{
	int i;
	int values[vooc->switch_gpios->ndescs];

	for (i = 0; i < vooc->switch_gpios->ndescs; i++)
		values[i] = enabled;

	vooc->fast_charge_enabled = enabled;
	gpiod_set_array_value_cansleep(vooc->switch_gpios->ndescs,
				       vooc->switch_gpios->desc, values);
}

void vooc_chip_step_clock(struct oppo_vooc_device *vooc) {
	gpiod_set_value_cansleep(vooc->clock_gpio, 0);
	usleep_range(1000, 1000);

	gpiod_set_value_cansleep(vooc->clock_gpio, 1);
	usleep_range(19000, 19000);
}

void vooc_chip_send_reply(struct oppo_vooc_device *vooc, int reply_info)
{
	int device_type = 0;

#ifdef CONFIG_BATTERY_GAUGE_OPPO_BQ27541
	if (bq27541_device_type >= 0)
		device_type = bq27541_device_type;
#endif

	// Set data GPIOs to sleep (output)
	gpiod_direction_output(vooc->data_gpio, 0);

	// Send data through data GPIOs
	gpiod_set_value_cansleep(vooc->data_gpio, reply_info >> 1);
	vooc_chip_step_clock(vooc);
	gpiod_set_value_cansleep(vooc->data_gpio, reply_info & 0x1);
	vooc_chip_step_clock(vooc);
	gpiod_set_value_cansleep(vooc->data_gpio, device_type);
	vooc_chip_step_clock(vooc);

	// Set data GPIOs to active (input)
	gpiod_direction_input(vooc->data_gpio);
}

static void vooc_reset_mcu(struct oppo_vooc_device *vooc)
{
	dev_dbg(vooc->dev, "reset mcu\n");

	// Put clock to sleep
	gpiod_set_value_cansleep(vooc->clock_gpio, 1);
	usleep_range(19000, 19000);

	// Perform reset operation
	gpiod_set_value_cansleep(vooc->reset_gpio, 0);
	usleep_range(5000, 5000);
	gpiod_set_value_cansleep(vooc->reset_gpio, 1);
	usleep_range(10000, 10000);
}

static void vooc_poll_func(struct work_struct *work)
{
	int i, data, bit;
	int chip_reply_info = 2; // FIXME: May also be returning 1
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, vooc_poll_work);
	struct device *dev = vooc->dev;

	dev_dbg(vooc->dev, "poll mcu\n");

	usleep_range(2000, 2000);
	if (!mutex_trylock(&vooc->lock))
		return;

	disable_irq(vooc->data_irq);

	// Check if data received start with "101"
	for (i = 0; i < 7; i++) {
		vooc_chip_step_clock(vooc);
		bit = gpiod_get_value_cansleep(vooc->data_gpio);
		data |= bit << (6 - i);

		if (i == 2 && data != 0x50 && !vooc->fw_update_required) {
			if (!vooc->fast_charge_enabled)
				goto out;

			dev_err(dev, "received errornous data: 0x%x\n", data);
			vooc_set_fast_charge_enabled(vooc, false);
			// TODO!
		}
	}

	dev_dbg(dev, "received data: 0x%x, fw version: 0x%x\n",
		 data, vooc->fw_data_version);

	switch (data) {
	case VOOC_NOTIFY_FAST_PRESENT:
		vooc_set_fast_charge_enabled(vooc, true);
		break;
	case VOOC_NOTIFY_FAST_ABSENT:
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	case VOOC_NOTIFY_ALLOW_READING_IIC:
		// TODO: Investigate whatever this does
		dev_info(dev, "chip reported to allowing reading i2c\n");
		break;
	case VOOC_NOTIFY_LOW_TEMP_FULL:
	case VOOC_NOTIFY_BAD_CONNECTED:
	case VOOC_NOTIFY_TEMP_OVER:
	case VOOC_NOTIFY_BTB_TEMP_OVER:
		dev_err(dev, "chip reported error, data: 0x%x\n", data);
	case VOOC_NOTIFY_NORMAL_TEMP_FULL:
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	case VOOC_NOTIFY_FIRMWARE_UPDATE:
	case VOOC_NOTIFY_ADAPTER_FW_UPDATE:
		dev_info(dev, "chip reported for fw update\n");
		schedule_work(&vooc->vooc_mcu_update_work);
		break;
	default:
		dev_err(dev, "received errornous data: 0x%x\n", data);
		vooc_set_fast_charge_enabled(vooc, false);
		break;
	}

	msleep(2);
	vooc_chip_send_reply(vooc, chip_reply_info);
out:
	vooc_chip_step_clock(vooc);
	enable_irq(vooc->data_irq);
	mutex_unlock(&vooc->lock);
}

static irqreturn_t vooc_irq_rx_handler(int irq, void *data)
{
	struct oppo_vooc_device *vooc = data;
	schedule_work(&vooc->vooc_poll_work);
	return IRQ_HANDLED;
}

static void vooc_mcu_firmware_loaded(const struct firmware *fw,
				    void *context)
{
	unsigned char *fw_data;
	struct oppo_vooc_device *vooc = context;
	int fw_size;

	if (!fw) {
		dev_err(vooc->dev, "Failed to read %s\n", fw_name);
		return;
	}

	mutex_lock(&vooc->lock);
	if (vooc->fw_data == NULL) {
		fw_data = devm_kzalloc(vooc->dev, fw->size, GFP_KERNEL);
		if (fw_data == NULL) {
			mutex_unlock(&vooc->lock);
			release_firmware(fw);
			dev_err(vooc->dev, "Error allocating memory\n");
			return;
		}

		fw_size = fw->size;
		memcpy(fw_data, fw->data, fw_size);
		release_firmware(fw);

		vooc->fw_data = fw_data;
		vooc->fw_data_count = fw_size;
		vooc->fw_data_version = fw_data[fw_size - 4];
	} else {
		dev_dbg(vooc->dev, "firmware file already loaded...\n");
		fw_data = vooc->fw_data;
		release_firmware(fw);
	}
	mutex_unlock(&vooc->lock);
}

static int vooc_load_mcu_firmware(struct oppo_vooc_device *vooc)
{
	return request_firmware_nowait(THIS_MODULE, FW_ACTION_HOTPLUG,
				       fw_name, vooc->dev, GFP_KERNEL,
				       vooc, vooc_mcu_firmware_loaded);
}

/* PIC16F MCU Firmware Management */
static int mcu_pic16f_check_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char addr_buf[2], data_buf[32];
	unsigned int current_addr, target_addr;
	int rc, i, fw_line = 0;

	if (vooc->fw_data == NULL)
		return -ENODATA;

	memcpy(addr_buf, (unsigned char[]){0x02, 0x00}, 2);
	memset(data_buf, 0, sizeof(data_buf));
	rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
	if (rc < 0) {
		dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
		return rc;
	}
	msleep(10);

	for (i = 0; i < MCU_PIC16F_READ_COUNT; i++) {
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[0]);
		msleep(2);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[16]);

		current_addr = 0x200 + (i * 16);
		target_addr = (vooc->fw_data[fw_line * 34 + 1] << 8) | vooc->fw_data[fw_line * 34];
		if (current_addr != target_addr)
			continue;

		if (memcmp(data_buf, &vooc->fw_data[fw_line * 34 + 2], 32) != 0) {
			dev_err(vooc->dev, "comparison failed %d\n", __LINE__);
			return -EINVAL;
		}

		fw_line++;
	}

	return 0;
}

static int mcu_pic16f_erase_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char zero_buf[1], addr_buf[2], temp_buf[1];
	unsigned int addr = 0x200;
	int rc = 0, i;

	memcpy(addr_buf, (unsigned char[]){0x02, 0x00}, 2);
	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

	// Erase 0x10 words at a time
	for (i = 0; i < MCU_PIC16F_ERASE_COUNT; i++) {
		dev_dbg(vooc->dev, "erase addr = 0x%x\n", addr);

		rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
		if (rc < 0) {
			dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
			return rc;
		}

		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_ERASE, 1, &zero_buf[0]);
		msleep(1);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_ERASE, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		addr = addr + 0x10;
		addr_buf[0] = addr >> 8;
		addr_buf[1] = addr & 0xFF;
	}

	return 0;
}

static int mcu_pic16f_write_firmware(struct oppo_vooc_device *vooc,
				     unsigned int offset, unsigned int length)
{
	unsigned int count = offset;
	unsigned char zero_buf[1], addr_buf[2], temp_buf[1];
	unsigned char *data_buf;
	int rc = 0, i;

	if (!vooc->fw_data)
		return -ENODATA;

	data_buf = devm_kmalloc(vooc->dev, 32, GFP_KERNEL);
	if (!data_buf)
		return -ENOMEM;

	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

	while (count < (offset + length)) {
		dev_dbg(vooc->dev, "write count %d\n", count);

		addr_buf[0] = vooc->fw_data[count + 1];
		addr_buf[1] = vooc->fw_data[count];

		rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
		if (rc < 0) {
			dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
			devm_kfree(vooc->dev, (void *)data_buf);
			return rc;
		}

		memcpy(data_buf, &vooc->fw_data[count + 2], 32);
		for (i = 0; i < 32; i += 2) {
			swab16s((u16 *)(data_buf + i));
		}

		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_WRITE, 16, data_buf);
		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &zero_buf[0]);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_WRITE, 16, data_buf + 16);
		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &zero_buf[0]);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		count = count + 2 + 32;
		msleep(2);

		if (count > (offset + length - 1))
			break;
	}

	devm_kfree(vooc->dev, (void *)data_buf);
	return 0;
}

static int mcu_pic16f_update_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char zero_buf[1], temp_buf[1];
	int rc = 0, retry = 0;

	if (vooc->fw_data == NULL)
		return -ENODATA;

	dev_dbg(vooc->dev, "%s enter\n", __func__);
	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

retry:
	rc = mcu_pic16f_erase_firmware(vooc);
	if (rc < 0) {
		dev_dbg(vooc->dev, "%s: Failed to erase firmware\n", __func__);
		return rc;
	}
	msleep(10);

	dev_dbg(vooc->dev, "%s: Write firmware #1\n", __func__);
	rc = mcu_pic16f_write_firmware(vooc, 0, vooc->fw_data_count - 34);
	if (rc < 0) {
		dev_err(vooc->dev, "%s: Failed to write firmware #1\n", __func__);
		return rc;
	}

	rc = mcu_pic16f_check_firmware(vooc);
	if (rc < 0) {
		retry++;
		if (retry > 3) {
			vooc->fw_checked = false;
			dev_err(vooc->dev, "%s: Check firmware attempts exhausted");
			return rc;
		}
		dev_err(vooc->dev, "%s: Failed to check firmware, retry = %d", retry);
		vooc_reset_mcu(vooc);
		goto retry;
	}

	// Write 0x7F0 - 0x7FF
	dev_dbg(vooc->dev, "%s: Write firmware #2\n", __func__);
	rc = mcu_pic16f_write_firmware(vooc, vooc->fw_data_count - 34, 34);
	if (rc < 0) {
		dev_err(vooc->dev, "%s: Failed to write firmware #2\n", __func__);
		return rc;
	}

	msleep(2);

	i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_EXEC, 1, &zero_buf[0]);
	i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_EXEC, 1, &temp_buf[0]);
	return 0;
}

/* STM8S MCU Firmware Management */
static int mcu_stm8s_check_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char addr_buf[2], data_buf[32];
	unsigned int current_addr, target_addr;
	int rc, i, fw_line = 0;

	if (vooc->fw_data == NULL)
		return -ENODATA;

	/* Front line */
	memcpy(addr_buf, (unsigned char[]){0x88, 0x00}, 2);
	memset(data_buf, 0, sizeof(data_buf));
	rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
	if (rc < 0) {
		dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
		return rc;
	}
	msleep(10);

	for (i = 0; i < MCU_STM8S_READ_COUNT; i++) {
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[0]);
		msleep(2);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[16]);

		current_addr = 0x8800 + (i * 32);
		target_addr = (vooc->fw_data[fw_line * 34 + 1] << 8) | vooc->fw_data[fw_line * 34];
		if (current_addr != target_addr)
			continue;

		if (memcmp(data_buf, &vooc->fw_data[fw_line * 34 + 2], 32) != 0) {
			dev_err(vooc->dev, "comparison failed %d\n", __LINE__);
			return -EINVAL;
		}

		fw_line++;
	}

	/* Last line */
	memcpy(addr_buf, (unsigned char[]){0x9F, 0x00}, 2);
	memset(data_buf, 0, sizeof(data_buf));
	rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
	if (rc < 0) {
		dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
		return rc;
	}
	msleep(2);
	i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[0]);
	msleep(2);
	i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_READ, 16, &data_buf[16]);

	if (memcmp(data_buf, &vooc->fw_data[vooc->fw_data_count - 32], 32) != 0) {
		dev_err(vooc->dev, "comparison failed %d\n", __LINE__);
		return -EINVAL;
	}

	return 0;
}

static int mcu_stm8s_erase_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char zero_buf[1], addr_buf[2], temp_buf[1];
	unsigned int addr = 0x8800;
	int rc = 0, i;

	memcpy(addr_buf, (unsigned char[]){0x88, 0x00}, 2);
	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

	// Erase 0x10 words at a time
	for (i = 0; i < MCU_STM8S_ERASE_COUNT; i++) {
		dev_dbg(vooc->dev, "erase addr = 0x%x\n", addr);

		rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
		if (rc < 0) {
			dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
			return rc;
		}

		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_ERASE, 1, &zero_buf[0]);
		msleep(1);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_ERASE, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		addr = addr + 0x10;
		addr_buf[0] = addr >> 8;
		addr_buf[1] = addr & 0xFF;
	}

	return 0;
}

static int mcu_stm8s_write_firmware(struct oppo_vooc_device *vooc,
				    unsigned int offset, unsigned int length)
{
	unsigned int count = offset;
	unsigned char zero_buf[1], addr_buf[2], temp_buf[1];
	int rc = 0;

	if (!vooc->fw_data)
		return -ENODATA;

	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

	while (count < (offset + length)) {
		dev_dbg(vooc->dev, "write count %d\n", count);

		addr_buf[0] = vooc->fw_data[count + 1];
		addr_buf[1] = vooc->fw_data[count];

		rc = i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_SET, 2, &addr_buf[0]);
		if (rc < 0) {
			dev_err(vooc->dev, "i2c write failed %d, rc = %d\n", __LINE__, rc);
			return rc;
		}

		i2c_smbus_write_i2c_block_data(vooc->client,
					       VOOC_REG_WRITE, 16, &vooc->fw_data[count + 2]);
		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &zero_buf[0]);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		i2c_smbus_write_i2c_block_data(vooc->client,
					       VOOC_REG_WRITE, 16, &vooc->fw_data[count + 2 + 16]);
		i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &zero_buf[0]);
		i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_REPORT, 1, &temp_buf[0]);
		dev_dbg(vooc->dev, "i2c read %d, temp_buf = 0x%x\n", __LINE__, temp_buf[0]);

		count = count + 2 + 32;
		msleep(2);

		if (count > (offset + length - 1))
			break;
	}

	return 0;
}

static int mcu_stm8s_update_firmware(struct oppo_vooc_device *vooc)
{
	unsigned char zero_buf[1], temp_buf[1];
	int rc = 0, retry = 0;

	if (vooc->fw_data == NULL)
		return -ENODATA;

	dev_dbg(vooc->dev, "%s enter\n", __func__);
	memset(zero_buf, 0, sizeof(zero_buf));
	memset(temp_buf, 0, sizeof(temp_buf));

retry:
	rc = mcu_stm8s_erase_firmware(vooc);
	if (rc < 0) {
		dev_dbg(vooc->dev, "%s: Failed to erase firmware\n", __func__);
		return rc;
	}
	msleep(10);

	dev_dbg(vooc->dev, "%s: Write firmware #1\n", __func__);
	rc = mcu_stm8s_write_firmware(vooc, 0, vooc->fw_data_count - 34);
	if (rc < 0) {
		dev_err(vooc->dev, "%s: Failed to write firmware #1\n", __func__);
		return rc;
	}

	rc = mcu_stm8s_check_firmware(vooc);
	if (rc < 0) {
		retry++;
		if (retry > 3) {
			vooc->fw_checked = false;
			dev_err(vooc->dev, "%s: Check firmware attempts exhausted");
			return rc;
		}
		dev_err(vooc->dev, "%s: Failed to check firmware, retry = %d", retry);
		vooc_reset_mcu(vooc);
		goto retry;
	}

	// Write 0x9FF0 - 0x9FFF
	dev_dbg(vooc->dev, "%s: Write firmware #2\n", __func__);
	rc = mcu_stm8s_write_firmware(vooc, vooc->fw_data_count - 34, 34);
	if (rc < 0) {
		dev_err(vooc->dev, "%s: Failed to write firmware #2\n", __func__);
		return rc;
	}

	msleep(2);

	i2c_smbus_write_i2c_block_data(vooc->client, VOOC_REG_EXEC, 1, &zero_buf[0]);
	i2c_smbus_read_i2c_block_data(vooc->client, VOOC_REG_EXEC, 1, &temp_buf[0]);
	return 0;
}

static void vooc_mcu_update_func(struct work_struct *work)
{
	int rc;
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, vooc_mcu_update_work);

	mutex_lock(&vooc->lock);
	disable_irq(vooc->data_irq);

	gpiod_set_value_cansleep(vooc->clock_gpio, 0);
	msleep(10);
	vooc_reset_mcu(vooc);
	gpiod_direction_output(vooc->data_gpio, 1);
	msleep(2500);
	gpiod_set_value_cansleep(vooc->clock_gpio, 1);

	rc = vooc_load_mcu_firmware(vooc);
	dev_dbg(vooc->dev, "Firmware loading requested: %d\n", rc);

	switch (vooc->id) {
	case MCU_PIC16F:
		rc = mcu_pic16f_check_firmware(vooc);
		if (rc < 0)
			rc = mcu_pic16f_update_firmware(vooc);
		break;
	case MCU_STM8S:
		rc = mcu_stm8s_check_firmware(vooc);
		if (rc < 0)
			rc = mcu_stm8s_update_firmware(vooc);
		break;
	default:
		dev_err(vooc->dev, "unknown mcu %d\n", vooc->id);
		return;
	}

	if (!rc) {
		vooc->fw_checked = true;
		dev_info(vooc->dev, "Firmware check successful\n");
	}

	msleep(5);
	vooc_reset_mcu(vooc);
	gpiod_direction_input(vooc->data_gpio);
	enable_irq(vooc->data_irq);
}

static bool vooc_is_batt_psy_available(struct oppo_vooc_device *vooc)
{
	if (!vooc->batt_psy)
		vooc->batt_psy = power_supply_get_by_name("battery");

	if (!vooc->batt_psy)
		return false;

	return true;
}

static void power_supply_changed_func(struct work_struct *work)
{
	int rc;
	union power_supply_propval pval = {0,};
	struct oppo_vooc_device *vooc = container_of(work,
			struct oppo_vooc_device, power_supply_changed_work);

	if (vooc_is_batt_psy_available(vooc)) {
		rc = power_supply_get_property(vooc->batt_psy,
					       POWER_SUPPLY_PROP_STATUS, &pval);
		if (rc < 0)
			dev_err(vooc->dev,
				"Error obtaining battery status, rc=%d\n", rc);

		if (pval.intval == POWER_SUPPLY_STATUS_CHARGING) {
			if (!vooc->fw_checked || vooc->fw_data == NULL)
				schedule_work(&vooc->vooc_mcu_update_work);
		}
	} else {
		dev_err(vooc->dev, "Error obtaining battery power supply\n");
	}
}

static int vooc_psy_notifier_cb(struct notifier_block *nb,
				 unsigned long event, void *data)
{
	struct power_supply *psy = data;
	struct oppo_vooc_device *vooc = container_of(nb, struct oppo_vooc_device, nb);

	if (strcmp(psy->desc->name, "battery") == 0) {
		pm_stay_awake(vooc->dev);
		schedule_work(&vooc->power_supply_changed_work);
	}

	return NOTIFY_OK;
}

static const struct of_device_id vooc_of_match[] = {
	{ .compatible = "oppo,pic16f-vooc", .data = (void *)MCU_PIC16F, },
	{ .compatible = "oppo,stm8s-vooc", .data = (void *)MCU_STM8S, },
	{}
};
MODULE_DEVICE_TABLE(of, vooc_of_match);

static int vooc_probe(struct i2c_client *client,
		      const struct i2c_device_id *id)
{
	int rc = 0;
	const char *fw_variant;

	struct oppo_vooc_device *vooc = devm_kzalloc(&client->dev,
						     sizeof(*vooc), GFP_KERNEL);
	if (!vooc) {
		dev_err(&client->dev, "no memory\n");
		rc = -ENOMEM;
		goto out;
	}

	vooc->client = client;
	vooc->dev = &client->dev;
	i2c_set_clientdata(client, vooc);

	if (client->dev.of_node) {
		const struct of_device_id *match;

		match = of_match_device(of_match_ptr(vooc_of_match),
				&client->dev);
		if (!match)
			return -ENODATA;
		vooc->id = (u32)((uintptr_t)match->data);
	} else {
		vooc->id = id->driver_data;
	}

	vooc->switch_gpios = devm_gpiod_get_array(&client->dev,
			"switch", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->switch_gpios)) {
		rc = PTR_ERR(vooc->switch_gpios);
		dev_err(&client->dev,
			"Failed to request GPIO switch pins, error rc=%d\n", rc);
		goto out;
	}

	vooc->reset_gpio = devm_gpiod_get(&client->dev,
				"reset", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->reset_gpio)) {
		rc = PTR_ERR(vooc->reset_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO reset pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->clock_gpio = devm_gpiod_get(&client->dev,
				"clock", GPIOD_OUT_LOW);
	if (IS_ERR(vooc->clock_gpio)) {
		rc = PTR_ERR(vooc->clock_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO clock pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->data_gpio = devm_gpiod_get(&client->dev,
				"data", GPIOD_IN);
	if (IS_ERR(vooc->data_gpio)) {
		rc = PTR_ERR(vooc->data_gpio);
		dev_err(&client->dev,
			"Failed to request GPIO data pin, error rc=%d\n", rc);
		goto out;
	}

	vooc->data_irq = gpiod_to_irq(vooc->data_gpio);
	if (vooc->data_gpio < 0) {
		rc = vooc->data_irq;
		goto out;
	}

	switch (vooc->id) {
	case MCU_PIC16F:
		dev_info(&client->dev, "selected pic16f fast mcu\n");
		break;
	case MCU_STM8S:
		dev_info(&client->dev, "selected stm8s fast mcu\n");
		break;
	default:
		dev_err(&client->dev, "unknown mcu %d\n", vooc->id);
		rc = -EINVAL;
		goto out;
	}

	vooc->nb.notifier_call = vooc_psy_notifier_cb;
	rc = power_supply_reg_notifier(&vooc->nb);
	if (rc < 0)
		dev_err(&client->dev,
			"Error registering psy notifier rc = %d\n", rc);

	mutex_init(&vooc->lock);

	INIT_WORK(&vooc->vooc_poll_work, vooc_poll_func);
	INIT_WORK(&vooc->vooc_mcu_update_work, vooc_mcu_update_func);
	INIT_WORK(&vooc->power_supply_changed_work, power_supply_changed_func);

	fw_variant = of_get_property(client->dev.of_node, "vooc,firmware-variant", NULL);
	if (fw_variant) {
		fw_name = devm_kasprintf(&client->dev,
					 GFP_KERNEL, "vooc_fw_%s.bin", fw_variant);
	}
	schedule_work(&vooc->vooc_mcu_update_work);

	rc = devm_request_irq(&client->dev, vooc->data_irq,
			      vooc_irq_rx_handler, IRQF_TRIGGER_RISING,
			      "vooc_mcu_data", vooc);
	if (rc < 0) {
		dev_err(&client->dev, "Request irq %d failed\n", vooc->data_irq);
		goto out;
	}

	return rc;

out:
	if (vooc)
		devm_kfree(&client->dev, (void *)vooc);
	return rc;
}

static int vooc_remove(struct i2c_client *client)
{
	struct oppo_vooc_device *vooc = i2c_get_clientdata(client);

	dev_dbg(&client->dev, "removed\n");
	if (!vooc)
		return 0;

	devm_kfree(&client->dev, (void *)vooc);

	return 0;
}

static const struct i2c_device_id vooc_i2c_ids[] = {
	{ "pic16f-vooc", MCU_PIC16F },
	{ "stm8s-vooc", MCU_STM8S },
	{},
};
MODULE_DEVICE_TABLE(i2c, vooc_i2c_ids);

static struct i2c_driver vooc_i2c_driver = {
	.driver = {
		.name	= "vooc-charger",
		.owner	= THIS_MODULE,
		.of_match_table = vooc_of_match,
	},
	.probe	= vooc_probe,
	.remove	= vooc_remove,
	.id_table = vooc_i2c_ids,
};
module_i2c_driver(vooc_i2c_driver);

MODULE_DESCRIPTION("OPPO VOOC charging driver");
MODULE_AUTHOR("Ricky Cheung <rcheung844@gmail.com>");
MODULE_LICENSE("GPL v2");
