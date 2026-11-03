import React, { memo } from 'react';
import cx from 'classnames';
import Styled from './styles';
import getTMeetIcon from '../tmeet-icons';

interface IconProps {
  iconName: string;
  prependIconName?: string;
  rotate?: boolean;
  className?: string;
  ariaLabel?: string;
  ariaHidden?: boolean;
}

const Icon: React.FC<IconProps> = ({
  ariaHidden,
  ariaLabel,
  className = '',
  prependIconName = 'icon-bbb-',
  iconName = '',
  rotate = false,
}) => {
  const isAriaHidden = ariaHidden ?? !ariaLabel;
  const TMeetIcon = prependIconName === 'icon-bbb-' ? getTMeetIcon(iconName) : undefined;

  return (
    <Styled.Icon
      aria-hidden={isAriaHidden}
      aria-label={isAriaHidden ? undefined : ariaLabel}
      role={isAriaHidden ? undefined : 'img'}
      className={cx(className, [prependIconName, iconName].join(''), { 'tmeet-icon': TMeetIcon })}
      $rotate={rotate}
    >
      {TMeetIcon && <TMeetIcon />}
    </Styled.Icon>
  );
};

export default memo(Icon);
