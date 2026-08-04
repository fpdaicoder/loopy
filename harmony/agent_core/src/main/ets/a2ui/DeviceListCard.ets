import {
  A2uiComponentDef,
  CreateSurfaceEnvelope,
  UpdateComponentsEnvelope,
  UpdateComponentsBody
} from './A2uiTypes';
import { A2UI_VERSION, AGENUI_CATALOG_ID, buildCreateSurface, newSurfaceId } from './A2uiProtocol';
import { DiscoveredDevice } from '../distributed/DeviceManagerClient';

const MAX_DEVICE_ROWS: number = 12;

/**
 * 拼装"发现的设备"列表卡片组件树（Card→Column→[标题, 每设备 Row, Divider]）。
 * 用宽松渲染路径支持的组件：Card / Column / Row / Text / Divider。
 * 设备名/deviceId 一字不差地写入，保证保真。
 */
export function buildDeviceListCardComponents(devices: DiscoveredDevice[]): A2uiComponentDef[] {
  const root: A2uiComponentDef = {
    id: 'root',
    component: 'Card',
    child: 'col'
  };
  const children: string[] = ['title'];
  const components: A2uiComponentDef[] = [root, {
    id: 'col',
    component: 'Column',
    children: children,
    align: 'stretch',
    justify: 'start'
  }, {
    id: 'title',
    component: 'Text',
    text: '发现的设备',
    variant: 'h3'
  }];

  const limit = devices.length > MAX_DEVICE_ROWS ? MAX_DEVICE_ROWS : devices.length;
  for (let index = 0; index < limit; index++) {
    const device = devices[index];
    const rowId = `row_${index}`;
    const nameId = `name_${index}`;
    const idId = `id_${index}`;
    const divId = `div_${index}`;
    children.push(rowId);
    components.push({
      id: rowId,
      component: 'Row',
      children: [nameId, idId],
      align: 'center',
      justify: 'space-between'
    });
    components.push({
      id: nameId,
      component: 'Text',
      text: device.deviceName.length > 0 ? device.deviceName : '(未命名设备)',
      variant: 'body'
    });
    components.push({
      id: idId,
      component: 'Text',
      text: device.deviceId,
      variant: 'caption'
    });
    components.push({
      id: divId,
      component: 'Divider'
    });
    children.push(divId);
  }

  if (devices.length === 0) {
    components.push({
      id: 'empty',
      component: 'Text',
      text: '未发现设备',
      variant: 'caption'
    });
    children.push('empty');
  }

  return components;
}

/**
 * 生成"发现的设备"卡片的 A2UI JSONL：createSurface 行 + updateComponents 行。
 * 与 ScriptedA2uiModel.generate 输出格式一致，走 ui 宽松渲染路径。
 * @returns 两行 JSON 字符串，用 '\n' 连接
 */
export function buildDeviceListCardJsonl(devices: DiscoveredDevice[]): string {
  const surfaceId = newSurfaceId();
  const createLine = buildCreateSurface(surfaceId);

  const components = buildDeviceListCardComponents(devices);
  const updateBody: UpdateComponentsBody = {
    surfaceId: surfaceId,
    components: components
  };
  const updateEnvelope: UpdateComponentsEnvelope = {
    version: A2UI_VERSION,
    updateComponents: updateBody
  };
  const componentsLine = JSON.stringify(updateEnvelope);

  return `${createLine}\n${componentsLine}`;
}
