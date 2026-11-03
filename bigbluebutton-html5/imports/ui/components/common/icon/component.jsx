import React, { memo } from 'react';
import PropTypes from 'prop-types';
import cx from 'classnames';
import { omit } from 'radash';
import Styled from './styles';
import getTMeetIcon from './tmeet-icons';

const propTypes = {
  iconName: PropTypes.string,
  prependIconName: PropTypes.string,
  rotate: PropTypes.bool,
  className: PropTypes.string,
  color: PropTypes.string,
};

const Icon = ({
  className = '',
  prependIconName = 'icon-bbb-',
  iconName,
  rotate = false,
  color = undefined,
  ...props
}) => {
  const TMeetIcon = prependIconName === 'icon-bbb-' ? getTMeetIcon(iconName) : undefined;

  return (
    <Styled.Icon
      aria-hidden="true"
      color={color}
      className={cx(
        className,
        iconName ? [prependIconName, iconName].join('') : '',
        { 'tmeet-icon': TMeetIcon },
      )}
      // ToastContainer from react-toastify passes a useless closeToast prop here
      {...omit(props, ['closeToast', 'animations', 'loading'])}
      $rotate={rotate}
    >
      {TMeetIcon && <TMeetIcon />}
    </Styled.Icon>
  );
};

export default memo(Icon);

Icon.propTypes = propTypes;
